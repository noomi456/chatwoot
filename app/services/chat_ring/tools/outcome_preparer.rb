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
    authorization = authorize_request!
    outbound_commit = ChatRing::OutboundCommitPreparer.call(turn, decision.decision_type)
    create_execution!(authorization, outbound_commit)
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
    ChatRing::Tools::RequestAppointmentAuthorization.call(turn, enforce_playbook_allowlist: true)
  end

  def create_execution!(authorization, outbound_commit)
    request = decision.tool_request
    ChatRing::Tools::RequestAppointmentExecutionBuilder.call(
      turn: turn,
      outbound_commit: outbound_commit,
      authorization: authorization,
      arguments: request.arguments,
      authorization_result: 'authorized'
    )
  end

  def reject!(code)
    raise Rejected, code
  end
end
