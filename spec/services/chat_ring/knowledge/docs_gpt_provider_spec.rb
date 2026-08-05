require 'rails_helper'

RSpec.describe ChatRing::Knowledge::DocsGptProvider do
  subject(:provider) do
    described_class.new(
      base_url: 'http://docsgpt.internal:7091',
      agent_api_key: 'agent-secret',
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'
    )
  end

  let(:search_url) { 'http://docsgpt.internal:7091/api/search' }
  let(:source_reference) { 'https://example.com/pricing' }
  let(:source_hash) { 'sha256:pricing-v1' }
  let(:source_manifest) { { source_reference => source_hash } }

  it 'maps documented DocsGPT search results into version-bound evidence' do
    stub_request(:post, search_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: [
        {
          text: 'The Pro plan costs $49 per month.',
          title: 'Pricing',
          source: source_reference
        }
      ].to_json
    )

    evidence_set = provider.retrieve(
      query: 'How much is Pro?',
      knowledge_version_id: 'knowledge-v1',
      source_content_hashes: source_manifest,
      limit: 4
    )

    expect(evidence_set.to_h).to include(
      knowledge_version_id: 'knowledge-v1',
      provider: 'docs_gpt',
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66',
      query: 'How much is Pro?',
      retrieval_strategy: 'docs_gpt_api_search',
      retrieval_configuration: { 'endpoint' => '/api/search', 'limit' => 4 }
    )
    expect(evidence_set.items.size).to eq(1)
    expect(evidence_set.items.first.to_h).to include(
      knowledge_version_id: 'knowledge-v1',
      provider_source_id: source_reference,
      source_reference: source_reference,
      source_title: 'Pricing',
      locator: 'Pricing',
      excerpt: 'The Pro plan costs $49 per month.',
      source_content_hash: source_hash,
      rank: 1,
      score: nil
    )
    expect(evidence_set.items.first.id).to match(/\A[0-9a-f]{64}\z/)
    expect(evidence_set.items).to be_frozen
    expect(evidence_set.retrieval_configuration).to be_frozen

    expect(WebMock).to have_requested(:post, search_url).with(
      headers: { 'Accept' => 'application/json', 'Content-Type' => 'application/json' },
      body: { question: 'How much is Pro?', api_key: 'agent-secret', chunks: 4 }.to_json
    ).once
  end

  it 'returns an empty evidence set when DocsGPT finds no supporting chunks' do
    stub_request(:post, search_url).to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: '[]')

    evidence_set = provider.retrieve(
      query: 'Unsupported question',
      knowledge_version_id: 'knowledge-v1',
      source_content_hashes: source_manifest
    )

    expect(evidence_set.items).to be_empty
  end

  it 'rejects evidence that is not bound to the selected knowledge-version manifest' do
    stub_request(:post, search_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: [{ text: 'Unknown content', title: 'Unknown', source: 'unpublished-source' }].to_json
    )

    expect do
      provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_content_hashes: source_manifest)
    end.to raise_error(described_class::ResponseError, /outside the knowledge-version manifest/)
  end

  it 'fails closed when the provider response does not match the documented result shape' do
    stub_request(:post, search_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { results: [] }.to_json
    )

    expect do
      provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_content_hashes: source_manifest)
    end.to raise_error(described_class::ResponseError, /must be an array/)
  end

  it 'reports the provider status without including its response body or API key' do
    stub_request(:post, search_url).to_return(status: 401, body: { error: 'Invalid API key agent-secret' }.to_json)

    expect do
      provider.retrieve(query: 'Question', knowledge_version_id: 'knowledge-v1', source_content_hashes: source_manifest)
    end.to raise_error(described_class::RequestError, 'DocsGPT retrieval failed with HTTP 401')
  end
end
