class ChatRing::Playbooks::InitialQuestionPreparer
  NOT_APPLICABLE = :not_applicable
  PREPARED = :prepared
  TERMINALIZED = :terminalized

  def self.call(turn, context_digest:)
    new(turn, context_digest: context_digest).call
  end

  def initialize(turn, context_digest:)
    @source_turn = turn
    @context_digest = context_digest
  end

  def call
    result = NOT_APPLICABLE
    Account.transaction do
      lock_native_scope!
      next unless initial_question?

      eligibility = ChatRing::Brain::Eligibility.check(turn)
      unless eligibility.eligible
        mark_ineligible!(eligibility.reason)
        result = TERMINALIZED
        next
      end

      prepare_question!
      result = PREPARED
    end
    result
  end

  private

  attr_reader :source_turn, :context_digest
  attr_accessor :turn, :execution, :conversation

  def lock_native_scope!
    Account.lock.find(source_turn.conversation.account_id)
    Inbox.lock.find(source_turn.conversation.inbox_id)
    self.conversation = Conversation.lock.find(source_turn.chatwoot_conversation_id)
    self.turn = ChatRing::AiTurn.lock.find(source_turn.id)
    self.execution = ChatRing::InboxPlaybookExecution.lock.find_by(id: turn.inbox_playbook_execution_id)
  end

  def initial_question?
    return false unless turn.status_running? && execution&.status_active?
    return false if execution.last_outcome_message_id.present?

    %w[ask_text ask_choice].include?(execution.current_step.to_h['kind'])
  end

  def prepare_question!
    content = ChatRing::Playbooks::QuestionRenderer.call(execution.current_step)
    ChatRing::OutboundCommitPreparer.call(turn, 'clarification')
    turn.update!(
      status: :ready_to_commit,
      decision_type: 'clarification',
      decision_payload: decision_payload(content),
      context_digest: context_digest,
      failure_code: nil,
      completed_at: Time.current
    )
  end

  def decision_payload(content)
    {
      'decision_type' => 'clarification',
      'response_text' => content,
      'reason_code' => 'playbook_question',
      'evidence_ids' => [],
      'playbook_control' => {
        'action' => 'ask_current_step'
      }
    }
  end

  def mark_ineligible!(reason)
    status = %w[newer_customer_message newer_human_reply].include?(reason) ? :superseded : :ineligible
    turn.update!(status: status, decision_type: reason, completed_at: Time.current)
    ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
      turn: turn,
      execution: execution,
      conversation: conversation,
      failure_code: reason
    )
  end
end
