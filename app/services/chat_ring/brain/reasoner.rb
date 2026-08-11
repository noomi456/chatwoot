class ChatRing::Brain::Reasoner
  Result = Data.define(:decision, :provider_result, :messages)

  def initialize(invocation:, evidence_set:, provider:)
    @invocation = invocation
    @evidence_set = evidence_set
    @provider = provider
  end

  def call
    messages = ChatRing::Brain::PromptBuilder.messages(
      context: invocation.model_context,
      evidence_set: evidence_set
    )
    yield messages if block_given?
    provider_result = provider.call(messages: messages)
    decision = ChatRing::Brain::Decision.from_payload(
      provider_result.payload,
      allowed_evidence_ids: evidence_set.items.map(&:id),
      evidence_status: evidence_set.status,
      playbook_context: invocation.model_context['active_playbook']
    )
    Result.new(decision: decision, provider_result: provider_result, messages: messages.freeze)
  end

  private

  attr_reader :invocation, :evidence_set, :provider
end
