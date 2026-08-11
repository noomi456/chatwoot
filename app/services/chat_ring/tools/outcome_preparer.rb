require 'digest'

class ChatRing::Tools::OutcomePreparer
  class Rejected < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  def self.call(turn, decision)
    new(turn, decision).call
  end

  def initialize(turn, decision)
    @turn = turn
    @decision = decision
  end

  def call
    Account.transaction do
      lock_native_scope!
      prepare_outcome!
    end
    true
  end

  private

  attr_reader :decision
  attr_accessor :turn

  def account
    conversation.account
  end

  def inbox
    conversation.inbox
  end

  def conversation
    turn.conversation
  end

  def validate_turn!
    reject!('tool_runtime_mode_unsupported') unless turn.runtime_mode_internal?
    reject!('tool_turn_not_running') unless turn.status_running?

    eligibility = ChatRing::Brain::Eligibility.check(turn)
    reject!(eligibility.reason) unless eligibility.eligible
  end

  def lock_native_scope!
    Account.lock.find(account.id)
    Inbox.lock.find(inbox.id)
    Conversation.lock.find(conversation.id)
    @turn = ChatRing::AiTurn.lock.find(turn.id)
  end

  def prepare_outcome!
    validate_turn!
    policy_version, capability = authorize_request!
    renderer_result = ChatRing::Tools::RequestAppointmentRenderer.call(policy_version)
    outbound_commit = ChatRing::OutboundCommitPreparer.call(turn, decision.decision_type)
    create_execution!(policy_version, capability, outbound_commit, renderer_result)
    mark_turn_ready!
  end

  def mark_turn_ready!
    turn.update!(
      status: :ready_to_commit,
      decision_type: decision.decision_type,
      decision_payload: decision.to_h,
      failure_code: nil,
      completed_at: Time.current
    )
  end

  def authorize_request!
    request = decision.tool_request
    reject!('tool_request_missing') unless request
    reject!('tool_not_granted') unless grant_set.include?(request.definition.key, request.definition.version)

    policy = current_policy
    reject!('tool_policy_unavailable') if policy&.current_version.blank?

    capability = capability_for(policy.current_version, request)
    reject!(capability.reason || 'tool_renderer_unavailable') unless capability.available
    [policy.current_version, capability]
  end

  def current_policy
    ChatRing::InboxToolPolicy.active.includes(:current_version).find_by(
      workspace_id: turn.workspace_id,
      chatwoot_inbox_id: inbox.id
    )
  end

  def capability_for(policy_version, request)
    ChatRing::Tools::InboxCapabilityProfile.new(inbox: inbox, policy_version: policy_version)
                                           .fetch(request.definition.key, request.definition.version)
  end

  def grant_set
    ChatRing::Tools::GrantSet.new(turn.assistant_version.tool_grants)
  rescue ChatRing::Tools::GrantSet::Invalid
    reject!('tool_grants_invalid')
  end

  def create_execution!(policy_version, capability, outbound_commit, renderer_result)
    request = decision.tool_request
    ChatRing::ToolExecution.create!(
      ai_turn: turn,
      inbox_tool_policy_version: policy_version,
      outbound_commit: outbound_commit,
      tool_key: request.definition.key,
      tool_version: request.definition.version,
      status: :pending,
      validated_arguments: request.arguments,
      result_payload: renderer_result.payload,
      authorization_result: 'authorized',
      renderer: capability.renderer,
      rendered_content: renderer_result.content,
      idempotency_key: Digest::SHA256.hexdigest(
        "chatring:tool:#{turn.workspace_id}:#{turn.id}:#{request.definition.identifier}"
      )
    )
  end

  def reject!(code)
    raise Rejected, code
  end
end
