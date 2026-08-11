class ChatRing::Playbooks::RejectedTurnFinalizer
  SUPERSEDED_TURN_FAILURES = %w[newer_customer_message newer_human_reply].freeze
  def self.call(turn, failure_code)
    new(turn, failure_code).call
  end

  def initialize(turn, failure_code)
    @source_turn = turn
    @failure_code = failure_code
  end

  def call
    Account.transaction do
      lock_native_scope!
      ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
        turn: turn,
        execution: execution,
        conversation: conversation,
        failure_code: failure_code
      )
      finalize_turn!
    end
  end

  private

  attr_reader :source_turn, :failure_code
  attr_accessor :turn, :conversation, :execution

  def lock_native_scope!
    Account.lock.find(source_turn.conversation.account_id)
    Inbox.lock.find(source_turn.conversation.inbox_id)
    self.conversation = Conversation.lock.find(source_turn.chatwoot_conversation_id)
    self.turn = ChatRing::AiTurn.lock.find(source_turn.id)
    self.execution = ChatRing::InboxPlaybookExecution.lock.find_by(id: turn.inbox_playbook_execution_id)
  end

  def finalize_turn!
    status = SUPERSEDED_TURN_FAILURES.include?(failure_code) ? :superseded : :cancelled
    turn.update!(status: status, failure_code: failure_code)
  end
end
