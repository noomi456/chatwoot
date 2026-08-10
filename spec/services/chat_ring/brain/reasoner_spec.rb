require 'rails_helper'

RSpec.describe ChatRing::Brain::Reasoner do
  it 'reasons over the immutable invocation contract without an AiTurn' do
    invocation = ChatRing::Brain::Invocation.new(
      kind: 'business_event',
      trusted_context: { 'account_id' => 1 },
      model_context: { 'assistant' => {}, 'conversation' => { 'history' => [] }, 'trigger_message' => {} },
      audit_metadata: { 'projection_version' => 1 },
      query: 'What changed?',
      deadline_at: 1.minute.from_now
    )
    evidence_set = ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: nil,
      provider: 'docs_gpt',
      provider_release: 'release',
      query: invocation.query,
      status: 'insufficient_evidence',
      error_code: nil,
      latency_ms: 0,
      retrieval_strategy: 'classic_cosine',
      retrieval_configuration: {},
      items: [].freeze
    )
    provider = instance_double(ChatRing::Brain::RubyLlmProvider)
    provider_result = ChatRing::Brain::RubyLlmProvider::Result.new(
      payload: { 'decision_type' => 'abstain', 'reason_code' => 'insufficient_evidence', 'evidence_ids' => [] },
      input_tokens: 3,
      output_tokens: 2,
      response_digest: Digest::SHA256.hexdigest('response')
    )
    allow(provider).to receive(:call).and_return(provider_result)

    result = described_class.new(invocation: invocation, evidence_set: evidence_set, provider: provider).call

    expect(result.decision).to have_attributes(decision_type: 'abstain', reason_code: 'insufficient_evidence')
    expect(result.provider_result).to eq(provider_result)
    expect(provider).to have_received(:call).once
  end
end
