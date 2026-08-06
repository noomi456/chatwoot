require 'rails_helper'

RSpec.describe ChatRing::Knowledge::DocsGptProvider do
  subject(:provider) do
    described_class.new(
      base_url: 'http://docsgpt.internal:7091',
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66',
      provider_source_id: 'source-uuid',
      account_id: '42',
      binding_digest: 'a' * 64,
      internal_key: 'internal-secret',
      service_secret: 'service-secret',
      score_threshold: 0.62
    )
  end

  let(:retrieval_url) { 'http://docsgpt.internal:7091/api/internal/chatring/retrieve' }
  let(:provider_source_reference) { '/app/inputs/001-pricing.md' }
  let(:source_reference) { 'https://example.com/pricing' }
  let(:source_hash) { 'sha256:pricing-v1' }
  let(:source_manifest) do
    {
      provider_source_reference => {
        content_hash: source_hash,
        source_reference: source_reference,
        source_title: 'Canonical pricing page',
        locator: 'Pricing > Pro',
        authority_class: 'structured_commercial'
      }
    }
  end

  def accepted_payload(authority_text: 'The Pro plan costs $49 per month.', score: 0.81)
    {
      status: 'accepted',
      source_id: 'source-uuid',
      latency_ms: 17,
      retrieval: { retriever: 'classic', score_threshold: 0.62 },
      chunks: [
        {
          rank: 1,
          chunk_id: '918',
          text: authority_text,
          title: 'Pricing',
          source: provider_source_reference,
          score: score,
          score_kind: 'cosine_similarity',
          metadata: { chatring_heading_path: 'Pricing > Pro' }
        }
      ]
    }
  end

  it 'returns scored, version-bound source evidence through the private Dispatcher endpoint' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload.to_json
    )

    evidence_set = provider.retrieve(
      query: 'How much is Pro?',
      knowledge_version_id: 'knowledge-v1',
      source_manifest: source_manifest,
      limit: 4
    )

    expect(evidence_set.to_h).to include(
      knowledge_version_id: 'knowledge-v1',
      status: 'accepted',
      error_code: nil,
      latency_ms: 17,
      retrieval_strategy: 'docs_gpt_dispatcher_classic_cosine'
    )
    expect(evidence_set.items.first.to_h).to include(
      provider_source_id: 'source-uuid',
      provider_chunk_id: '918',
      source_reference: source_reference,
      locator: 'Pricing > Pro',
      authority_class: 'structured_commercial',
      source_content_hash: source_hash,
      score: 0.81,
      score_kind: 'cosine_similarity'
    )
    expect(evidence_set.items.first.id).to match(/\A[0-9a-f]{64}\z/)
    request_matcher = have_requested(:post, retrieval_url).with do |request|
      body = JSON.parse(request.body)
      headers = request.headers.transform_keys(&:downcase)
      headers['x-internal-key'] == 'internal-secret' &&
        headers['x-chatring-account'] == '42' &&
        headers['x-chatring-knowledge-version'] == 'knowledge-v1' &&
        headers['x-chatring-binding-digest'] == 'a' * 64 &&
        headers['x-chatring-signature'].match?(/\A[0-9a-f]{64}\z/) &&
        body == { 'query' => 'How much is Pro?', 'source_id' => 'source-uuid', 'limit' => 4, 'score_threshold' => 0.62 }
    end
    expect(WebMock).to request_matcher
  end

  it 'returns a real insufficient-evidence result rather than forced top-k passages' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'insufficient_evidence', source_id: 'source-uuid', chunks: [] }.to_json
    )

    result = provider.retrieve(
      query: 'What is the capital of France?',
      knowledge_version_id: 'knowledge-v1',
      source_manifest: source_manifest
    )

    expect(result.status).to eq('insufficient_evidence')
    expect(result.items).to be_empty
  end

  it 'does not accept compliance claims from marketing pages' do
    marketing_manifest = source_manifest.deep_dup
    marketing_manifest[provider_source_reference][:authority_class] = 'marketing'
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(authority_text: 'We are SOC 2 compliant.').to_json
    )

    result = provider.retrieve(
      query: 'Is ChatRing SOC2 compliant?',
      knowledge_version_id: 'knowledge-v1',
      source_manifest: marketing_manifest
    )

    expect(result.status).to eq('insufficient_evidence')
    expect(result.items).to be_empty
  end

  it 'does not answer legal-policy questions from pricing or marketing evidence' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(authority_text: 'The Lite plan costs $29 per month.').to_json
    )

    result = provider.retrieve(
      query: 'What is the refund policy?',
      knowledge_version_id: 'knowledge-v1',
      source_manifest: source_manifest
    )

    expect(result.status).to eq('insufficient_evidence')
    expect(result.items).to be_empty
  end

  it 'rejects unscored provider results' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(score: nil).to_json
    )

    expect do
      provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_manifest: source_manifest)
    end.to raise_error(described_class::ResponseError, /missing numeric score/)
  end

  it 'rejects evidence outside the selected version manifest' do
    payload = accepted_payload
    payload[:chunks][0][:source] = 'unpublished-source'
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: payload.to_json
    )

    expect do
      provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_manifest: source_manifest)
    end.to raise_error(described_class::ResponseError, /outside the knowledge-version manifest/)
  end

  it 'keeps provider failure distinct from insufficient evidence' do
    stub_request(:post, retrieval_url).to_return(
      status: 503,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'provider_error' }.to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_manifest: source_manifest)
    expect(result.status).to eq('provider_error')
    expect(result.error_code).to eq('provider_error')
  end

  it 'requires an exact SHA-256 content binding' do
    expect do
      described_class.new(
        base_url: 'http://docsgpt.internal:7091',
        provider_release: 'release',
        provider_source_id: 'source-uuid',
        account_id: '42',
        binding_digest: 'not-a-digest',
        internal_key: 'internal-secret',
        service_secret: 'service-secret',
        score_threshold: 0.62
      )
    end.to raise_error(described_class::ConfigurationError, /binding_digest must be a SHA-256 digest/)
  end
end
