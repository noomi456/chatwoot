require 'rails_helper'

RSpec.describe ChatRing::Knowledge::EvaluationService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ready',
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66',
      root_url: 'https://example.com/',
      manifest_digest: 'manifest-v1',
      config_snapshot: { 'retrieval' => { 'score_threshold' => 0.62 } }
    )
  end
  let(:provider) { instance_double(ChatRing::Knowledge::DocsGptProvider) }
  let(:cases) do
    [
      accepted_case('positive 1', 'positive'),
      accepted_case('positive 2', 'positive'),
      accepted_case('positive 3', 'positive'),
      accepted_case('positive 4', 'positive'),
      accepted_case('ambiguous supported', 'ambiguous'),
      negative_case('unsupported 1', 'unsupported'),
      negative_case('unsupported 2', 'unsupported'),
      negative_case('adversarial 1', 'adversarial'),
      negative_case('adversarial 2', 'adversarial'),
      negative_case('compliance claim', 'compliance')
    ]
  end

  def accepted_case(query, category)
    {
      query: query,
      category: category,
      expectation: 'accepted',
      expected_urls: ['https://example.com/docs'],
      expected_text: 'expected phrase'
    }
  end

  def negative_case(query, category)
    { query: query, category: category, expectation: 'insufficient_evidence' }
  end

  def result(status, items = [])
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_version_id: version.id.to_s,
      provider: 'docs_gpt',
      provider_release: version.provider_release,
      query: 'query',
      status: status,
      error_code: nil,
      latency_ms: 1,
      retrieval_strategy: 'classic',
      retrieval_configuration: {},
      items: items
    )
  end

  it 'persists a passed evaluation bound to the current corpus and configuration' do
    evidence = Struct.new(:source_reference, :id, :excerpt).new(
      'https://example.com/docs', 'evidence-1', 'This contains the expected phrase.'
    )
    allow(provider).to receive(:retrieve) do |query:, **|
      query.start_with?('positive', 'ambiguous') ? result('accepted', [evidence]) : result('insufficient_evidence')
    end

    report = described_class.evaluate!(version, cases: cases, provider: provider)

    expect(report).to include('case_count' => 10, 'passed_count' => 10)
    expect(version.reload.evaluation_passed_for_current_content?).to be(true)
  end

  it 'fails the gate when retrieved evidence comes from the wrong source' do
    evidence = Struct.new(:source_reference, :id, :excerpt).new(
      'https://example.com/pricing', 'wrong-evidence', 'This contains the expected phrase.'
    )
    allow(provider).to receive(:retrieve) do |query:, **|
      query.start_with?('positive', 'ambiguous') ? result('accepted', [evidence]) : result('insufficient_evidence')
    end

    expect { described_class.evaluate!(version, cases: cases, provider: provider) }.to raise_error(
      described_class::Error,
      /failed 5 evaluation case/
    )
    expect(version.reload.evaluation_status).to eq('failed')
  end
end
