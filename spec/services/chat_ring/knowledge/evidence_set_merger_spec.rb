require 'rails_helper'

RSpec.describe ChatRing::Knowledge::EvidenceSetMerger do
  it 'keeps the strongest copy of each chunk and reranks the bounded union' do
    result = described_class.call(
      [
        evidence_set('raw query', [evidence('shared', 0.61, 1), evidence('raw-only', 0.55, 2)]),
        evidence_set('context query', [evidence('shared', 0.83, 2), evidence('context-only', 0.72, 1)])
      ],
      limit: 2
    )

    expect(result).to have_attributes(status: 'accepted', query: 'raw query', retrieval_strategy: 'dual_query_max_score')
    expect(result.items.map { |item| [item.provider_chunk_id, item.score, item.rank] }).to eq(
      [['shared', 0.83, 1], ['context-only', 0.72, 2]]
    )
    expect(result.retrieval_configuration).to include('fusion' => 'max_score', 'query_count' => 2)
    expect(result.retrieval_configuration.to_json).not_to include('raw query', 'context query')
  end

  it 'fails the combined retrieval closed when either provider request fails' do
    result = described_class.call(
      [
        evidence_set('raw query', [evidence('raw-only', 0.75, 1)]),
        evidence_set('context query', [], status: 'provider_error', error_code: 'provider_timeout')
      ]
    )

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_timeout', items: [])
  end

  it 'returns an existing single-query result without changing its retrieval contract' do
    original = evidence_set('raw query', [evidence('raw-only', 0.75, 1)])

    expect(described_class.call([original])).to equal(original)
  end

  it 'rejects score fusion across different retrieval contracts' do
    first = evidence_set('raw query', [evidence('raw-only', 0.75, 1)])
    second = evidence_set(
      'context query', [evidence('context-only', 0.76, 1)],
      retrieval_configuration: retrieval_configuration.merge('candidate_selection' => 'legacy_cosine_threshold')
    )

    expect { described_class.call([first, second]) }
      .to raise_error(ChatRing::Knowledge::Retriever::Error, 'Evidence fusion retrieval contract mismatch')
  end

  it 'rejects incomparable score kinds instead of taking their numeric maximum' do
    first = evidence_set('raw query', [evidence('raw-only', 0.75, 1)])
    lexical = evidence('context-only', 0.76, 1, score_kind: 'rrf')

    expect { described_class.call([first, evidence_set('context query', [lexical])]) }
      .to raise_error(ChatRing::Knowledge::Retriever::Error, 'Evidence fusion retrieval contract mismatch')
  end

  it 'never promotes conversational reference text into Knowledge evidence' do
    result = described_class.call(
      [
        evidence_set('Does it support Salesforce?', [evidence('knowledge-only', 0.75, 1)]),
        evidence_set('A human said Salesforce is supported. Does it support Salesforce?', [])
      ]
    )

    expect(result.items.map(&:excerpt)).to eq(['knowledge-only'])
    expect(result.items.map(&:excerpt).join).not_to include('A human said Salesforce is supported')
  end

  def evidence_set(query, items, status: 'accepted', error_code: nil, retrieval_configuration: nil)
    retrieval_configuration ||= self.retrieval_configuration
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: 'index-1', provider: 'docs_gpt', provider_release: 'release', query: query,
      status: status, error_code: error_code, latency_ms: 2,
      retrieval_strategy: ChatRing::Knowledge::DocsGptProvider::RETRIEVAL_STRATEGY,
      retrieval_configuration: retrieval_configuration, items: items.freeze
    )
  end

  def retrieval_configuration
    {
      'endpoint' => '/api/internal/chatring/retrieve', 'limit' => 8,
      'candidate_selection' => 'exact_top_k', 'binding_digest' => 'a' * 64
    }
  end

  def evidence(chunk_id, score, rank, score_kind: 'cosine_similarity')
    ChatRing::Knowledge::Evidence.new(
      id: chunk_id, knowledge_index_id: 'index-1', provider: 'docs_gpt', provider_release: 'release',
      provider_source_id: 'source', provider_chunk_id: chunk_id, source_kind: 'website',
      source_reference: "https://example.com/#{chunk_id}", source_title: chunk_id, public_url: "https://example.com/#{chunk_id}",
      heading_path: [], page_locator: nil, page_headings: [], cta_candidates: [], locator: chunk_id,
      authority_class: 'product_documentation', risk_flags: [], excerpt: chunk_id,
      source_content_hash: Digest::SHA256.hexdigest(chunk_id), rank: rank, score: score,
      score_kind: score_kind, retrieval_strategy: ChatRing::Knowledge::DocsGptProvider::RETRIEVAL_STRATEGY
    )
  end
end
