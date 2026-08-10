class Conversations::AgentBotConditionalHandoffService
  Result = Data.define(:conversation, :idempotent)

  def initialize(turn:, outbound_commit:)
    @turn = turn
    @outbound_commit = outbound_commit
  end

  def perform
    conversation, idempotent, failure_code = commit_inside_serialization_boundary
    raise Conversations::AgentBotConditionalCommitService::PreconditionFailed, failure_code if failure_code

    conversation.dispatch_bot_handoff_event unless idempotent
    Result.new(conversation: conversation, idempotent: idempotent)
  end

  private

  attr_reader :turn, :outbound_commit

  def commit_inside_serialization_boundary
    ActiveRecord::Base.transaction do
      Inbox.lock.find(turn.conversation.inbox_id)
      conversation = Conversation.lock.find(turn.chatwoot_conversation_id)
      outbound_commit.lock!
      validate_ledger!(conversation)
      idempotent = outbound_commit.status_committed?
      failure_code = existing_failure_code || (commit_handoff(conversation) unless idempotent)
      [conversation, idempotent, failure_code]
    end
  end

  def commit_handoff(conversation)
    eligibility = ChatRing::Brain::Eligibility.check(turn.reload)
    return reject_handoff(eligibility.reason) unless eligibility.eligible

    conversation.bot_handoff!(dispatch_event: false)
    outbound_commit.update!(status: :committed, attempted_at: Time.current, committed_at: Time.current, failure_code: nil)
    nil
  end

  def reject_handoff(failure_code)
    outbound_commit.update!(status: :rejected, attempted_at: Time.current, failure_code: failure_code)
    failure_code
  end

  def existing_failure_code
    return unless outbound_commit.status_rejected?

    outbound_commit.failure_code.presence || 'commit_rejected'
  end

  def validate_ledger!(conversation)
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless outbound_commit.ai_turn_id == turn.id
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless outbound_commit.outcome_type_handoff?
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless turn.chatwoot_conversation_id == conversation.id
  end
end
