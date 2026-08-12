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
      retrieval_configuration: {
        strategy: described_class::RETRIEVAL_STRATEGY,
        candidate_selection: 'exact_top_k'
      }
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
        authority_class: 'structured_commercial',
        headings: [
          { level: 1, text: 'Pricing', path: 'Pricing' },
          { level: 2, text: 'Pro', path: 'Pricing > Pro' }
        ],
        cta_candidates: [
          { label: 'Contact Sales', url: 'https://sales.example.net/contact', heading_path: 'Pricing', external: true },
          { label: 'Start Trial', url: 'https://example.com/signup', heading_path: 'Pricing > Pro', external: false }
        ]
      }
    }
  end

  def accepted_payload(authority_text: 'The Pro plan costs $49 per month.', score: 0.81) # rubocop:disable Metrics/MethodLength
    {
      status: 'accepted',
      source_id: 'source-uuid',
      latency_ms: 17,
      retrieval: { retriever: 'classic', score_threshold: nil },
      chunks: [
        {
          rank: 1,
          chunk_id: '918',
          text: authority_text,
          title: 'Pricing',
          source: provider_source_reference,
          score: score,
          score_kind: 'cosine_similarity',
          metadata: {
            chatring_heading_path: 'Pricing > Pro',
            chatring_content_hash: Digest::SHA256.hexdigest(authority_text)
          }
        }
      ]
    }
  end

  it 'returns scored, index-bound source evidence through the private Dispatcher endpoint' do # rubocop:disable RSpec/ExampleLength
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload.to_json
    )

    evidence_set = provider.retrieve(
      query: 'How much is Pro?',
      knowledge_index_id: 'knowledge-v1',
      source_manifest: source_manifest,
      limit: 4
    )

    expect(evidence_set.to_h).to include(
      knowledge_index_id: 'knowledge-v1',
      status: 'accepted',
      error_code: nil,
      latency_ms: 17,
      retrieval_strategy: 'docs_gpt_dispatcher_classic_exact_candidates'
    )
    expect(evidence_set.items.first.to_h).to include(
      provider_source_id: 'source-uuid',
      provider_chunk_id: '918',
      source_reference: source_reference,
      heading_path: 'Pricing > Pro',
      locator: 'Pricing > Pro',
      authority_class: 'structured_commercial',
      source_content_hash: source_hash,
      score: 0.81,
      score_kind: 'cosine_similarity'
    )
    expect(evidence_set.items.first.page_headings.map(&:to_h)).to eq(
      [
        { level: 1, text: 'Pricing', path: 'Pricing' },
        { level: 2, text: 'Pro', path: 'Pricing > Pro' }
      ]
    )
    expect(evidence_set.items.first.cta_candidates.map(&:to_h)).to eq(
      [
        { label: 'Start Trial', url: 'https://example.com/signup', heading_path: 'Pricing > Pro', external: false }
      ]
    )
    expect(evidence_set.items.first.id).to match(/\A[0-9a-f]{64}\z/)
    request_matcher = have_requested(:post, retrieval_url).with do |request|
      body = JSON.parse(request.body)
      headers = request.headers.transform_keys(&:downcase)
      headers['x-internal-key'] == 'internal-secret' &&
        headers['x-chatring-account'] == '42' &&
        headers['x-chatring-knowledge-index'] == 'knowledge-v1' &&
        headers['x-chatring-binding-digest'] == 'a' * 64 &&
        headers['x-chatring-signature'].match?(/\A[0-9a-f]{64}\z/) &&
        body == { 'query' => 'How much is Pro?', 'source_id' => 'source-uuid', 'limit' => 20 }
    end
    expect(WebMock).to request_matcher
  end

  it 'preserves a provider-reported empty candidate set' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'insufficient_evidence', source_id: 'source-uuid', chunks: [] }.to_json
    )

    result = provider.retrieve(
      query: 'What is the capital of France?',
      knowledge_index_id: 'knowledge-v1',
      source_manifest: source_manifest
    )

    expect(result.status).to eq('insufficient_evidence')
    expect(result.items).to be_empty
  end

  it 'keeps a finite low-similarity candidate for the Brain instead of treating cosine as factual support' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(score: 0.28).to_json
    )

    result = provider.retrieve(
      query: 'How do Playbooks work?',
      knowledge_index_id: 'knowledge-v1',
      source_manifest: source_manifest
    )

    expect(result).to have_attributes(status: 'accepted')
    expect(result.items.first).to have_attributes(score: 0.28, score_kind: 'cosine_similarity')
    expect(result.retrieval_configuration).to include('candidate_selection' => 'exact_top_k')
  end

  it 'preserves the stored threshold for an immutable legacy index' do
    legacy_provider = described_class.new(
      base_url: 'http://docsgpt.internal:7091', provider_release: '616e6fe9', provider_source_id: 'source-uuid',
      account_id: '42', binding_digest: 'a' * 64, internal_key: 'internal-secret', service_secret: 'service-secret',
      retrieval_configuration: { strategy: described_class::LEGACY_RETRIEVAL_STRATEGY, score_threshold: 0.40 }
    )
    stub_request(:post, retrieval_url).to_return(
      status: 200, headers: { 'Content-Type' => 'application/json' }, body: accepted_payload(score: 0.28).to_json
    )

    result = legacy_provider.retrieve(
      query: 'How do Playbooks work?', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest
    )

    expect(result).to have_attributes(
      status: 'insufficient_evidence', retrieval_strategy: described_class::LEGACY_RETRIEVAL_STRATEGY
    )
    expect(result.retrieval_configuration).to include(
      'candidate_selection' => 'legacy_cosine_threshold', 'score_threshold' => 0.40
    )
  end

  it 'returns compliance and legal evidence with authority metadata for the Brain to evaluate' do
    marketing_manifest = source_manifest.deep_dup
    marketing_manifest[provider_source_reference][:authority_class] = 'marketing'
    marketing_manifest[provider_source_reference][:risk_flags] = ['possible_compliance_claim']
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(authority_text: 'We are SOC 2 compliant.').to_json
    )

    result = provider.retrieve(
      query: 'Is ChatRing SOC2 compliant?',
      knowledge_index_id: 'knowledge-v1',
      source_manifest: marketing_manifest
    )

    expect(result.status).to eq('accepted')
    expect(result.items.first).to have_attributes(
      authority_class: 'marketing',
      risk_flags: ['possible_compliance_claim']
    )
  end

  it 'normalizes an unscored provider result as a typed invalid response' do
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(score: nil).to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_invalid_response', items: [])
  end

  it 'normalizes a non-finite provider score as a typed invalid response' do
    body = accepted_payload.to_json.sub('"score":0.81', '"score":1e400')
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: body
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_invalid_response', items: [])
  end

  it 'normalizes tampered provider text as a typed integrity failure' do
    payload = accepted_payload
    payload[:chunks][0][:text] = 'Tampered provider excerpt'
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: payload.to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_integrity_error', items: [])
  end

  it 'preserves provider whitespace while validating the stable chunk hash' do
    authority_text = "\n# Pricing\n\nThe Pro plan costs $49 per month.\n"
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload(authority_text: authority_text).to_json
    )

    result = provider.retrieve(
      query: 'How much is Pro?',
      knowledge_index_id: 'knowledge-v1',
      source_manifest: source_manifest
    )

    expect(result.items.first.excerpt).to eq(authority_text)
  end

  it 'normalizes evidence outside the active index manifest as a typed integrity failure' do
    payload = accepted_payload
    payload[:chunks][0][:source] = 'unpublished-source'
    stub_request(:post, retrieval_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: payload.to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_integrity_error', items: [])
  end

  it 'keeps provider failure distinct from insufficient evidence' do
    stub_request(:post, retrieval_url).to_return(
      status: 503,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'provider_error' }.to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)
    expect(result.status).to eq('provider_error')
    expect(result.error_code).to eq('provider_unavailable')
  end

  it 'never accepts evidence from an HTTP 503 response' do
    stub_request(:post, retrieval_url).to_return(
      status: 503,
      headers: { 'Content-Type' => 'application/json' },
      body: accepted_payload.to_json
    )

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_unavailable', items: [])
  end

  {
    401 => 'provider_authentication_failed',
    403 => 'provider_authentication_failed',
    404 => 'provider_source_missing',
    429 => 'provider_rate_limited',
    500 => 'provider_unavailable'
  }.each do |status, error_code|
    it "normalizes HTTP #{status} as #{error_code}" do
      stub_request(:post, retrieval_url).to_return(status: status, body: 'provider failure')

      result = provider.retrieve(
        query: 'Question',
        knowledge_index_id: 'knowledge-v1',
        source_manifest: source_manifest
      )

      expect(result).to have_attributes(status: 'provider_error', error_code: error_code, items: [])
    end
  end

  it 'keeps transport timeouts distinct from insufficient evidence' do
    stub_request(:post, retrieval_url).to_timeout

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)

    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_timeout', items: [])
  end

  [EOFError, Errno::ECONNABORTED, Errno::ECONNRESET, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError].each do |error_class|
    it "normalizes #{error_class} as a connection failure" do
      stub_request(:post, retrieval_url).to_raise(error_class.new)

      result = provider.retrieve(
        query: 'Question',
        knowledge_index_id: 'knowledge-v1',
        source_manifest: source_manifest
      )

      expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_connection_failed', items: [])
    end
  end

  it 'normalizes malformed successful responses without hiding local configuration errors' do
    stub_request(:post, retrieval_url).to_return(status: 200, body: 'not-json')

    result = provider.retrieve(query: 'Question', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)
    expect(result).to have_attributes(status: 'provider_error', error_code: 'provider_invalid_response', items: [])

    expect do
      provider.retrieve(query: '', knowledge_index_id: 'knowledge-v1', source_manifest: source_manifest)
    end.to raise_error(described_class::ConfigurationError, /query is required/)
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
        retrieval_configuration: { strategy: described_class::RETRIEVAL_STRATEGY, candidate_selection: 'exact_top_k' }
      )
    end.to raise_error(described_class::ConfigurationError, /binding_digest must be a SHA-256 digest/)
  end

  it 'rejects an unsafe CTA URL from the active index manifest' do
    unsafe_manifest = source_manifest.deep_dup
    unsafe_manifest[provider_source_reference][:cta_candidates][0][:url] = 'javascript:alert(1)'

    expect do
      provider.retrieve(
        query: 'Question',
        knowledge_index_id: 'knowledge-v1',
        source_manifest: unsafe_manifest
      )
    end.to raise_error(described_class::ConfigurationError, /CTA url must be a safe public http or https URL/)

    unsafe_manifest[provider_source_reference][:cta_candidates][0][:url] = 'http://127.0.0.1/admin'
    expect do
      provider.retrieve(
        query: 'Question',
        knowledge_index_id: 'knowledge-v1',
        source_manifest: unsafe_manifest
      )
    end.to raise_error(described_class::ConfigurationError, /CTA url must be a safe public http or https URL/)
  end
end
