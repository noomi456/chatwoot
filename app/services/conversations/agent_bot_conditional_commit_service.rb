class Conversations::AgentBotConditionalCommitService
  class Unauthorized < StandardError; end

  class PreconditionFailed < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  Result = Data.define(:message, :idempotent)

  def initialize(conversation:, agent_bot:, **options)
    @original_conversation = conversation
    @agent_bot = agent_bot
    @expected_agent_bot_id = options.fetch(:expected_agent_bot_id).to_i
    @responding_to_message_id = options.fetch(:responding_to_message_id).to_i
    @idempotency_key = options.fetch(:idempotency_key).to_s
    @message_attributes = options.fetch(:message).to_h.symbolize_keys.slice(:content, :content_type)
  end

  def perform
    authorize!
    result = commit_inside_serialization_boundary
    raise PreconditionFailed, result.failure_code if result.status_rejected?

    Result.new(message: result.message, idempotent: @idempotent)
  end

  private

  attr_reader :agent_bot, :expected_agent_bot_id, :responding_to_message_id, :idempotency_key, :message_attributes

  def conversation
    @locked_conversation || @original_conversation
  end

  def authorize!
    raise Unauthorized unless agent_bot.is_a?(AgentBot) && agent_bot.chatring_assistant?
    raise Unauthorized unless agent_bot.account_id.present? && agent_bot.account_id == conversation.account_id
    raise Unauthorized unless agent_bot.id == expected_agent_bot_id
  end

  def commit_inside_serialization_boundary
    result = nil
    ActiveRecord::Base.transaction do
      Inbox.lock.find(conversation.inbox_id)
      @locked_conversation = Conversation.lock.find(conversation.id)
      begin
        outbound_commit = ChatRing::OutboundCommit.lock.find_by!(idempotency_key: idempotency_key)
        validate_ledger!(outbound_commit)
        @idempotent = outbound_commit.status_committed?
        result = outbound_commit.status_committed? ? outbound_commit : commit_or_reject(outbound_commit)
      ensure
        @locked_conversation = nil
      end
    end
    result
  end

  def validate_ledger!(outbound_commit)
    turn = outbound_commit.ai_turn
    raise Unauthorized unless outbound_commit.outcome_type_reply? || outbound_commit.outcome_type_tool?
    raise Unauthorized unless turn.chatwoot_conversation_id == conversation.id
    raise Unauthorized unless turn.expected_agent_bot_id == agent_bot.id
  end

  def commit_or_reject(outbound_commit)
    failure_code = precondition_failure(outbound_commit)
    return reject(outbound_commit, failure_code) if failure_code

    message = create_message(outbound_commit.ai_turn)
    outbound_commit.update!(
      status: :committed,
      chatwoot_message_id: message.id,
      attempted_at: Time.current,
      committed_at: Time.current,
      failure_code: nil
    )
    outbound_commit
  end

  def precondition_failure(outbound_commit)
    turn = outbound_commit.ai_turn
    return outbound_failure(outbound_commit: outbound_commit) if outbound_commit.status_rejected?
    return 'invalid_message' unless valid_message_payload?
    return 'invalid_trigger_message' unless valid_trigger_message?(turn)

    eligibility = ChatRing::Brain::Eligibility.check(turn.reload)
    return eligibility.reason unless eligibility.eligible

    return unless outbound_commit.outcome_type_tool?

    tool_eligibility = ChatRing::Tools::CommitEligibility.check(execution: outbound_commit.tool_execution, turn: turn)
    return tool_eligibility.reason unless tool_eligibility.eligible
  end

  def outbound_failure(outbound_commit:)
    outbound_commit.failure_code.presence || 'commit_rejected'
  end

  def valid_trigger_message?(turn)
    return false unless turn.trigger_message_id == responding_to_message_id

    message = Message.find_by(id: responding_to_message_id)
    return false unless message

    message.conversation_id == conversation.id && message.incoming? && !message.private? && message.sender_type == 'Contact'
  end

  def valid_message_payload?
    message_attributes[:content].to_s.strip.present? && (message_attributes[:content_type].presence || 'text').to_s == 'text'
  end

  def reject(outbound_commit, failure_code)
    outbound_commit.update!(status: :rejected, attempted_at: Time.current, failure_code: failure_code)
    outbound_commit
  end

  def create_message(turn)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: agent_bot,
      message_type: :outgoing,
      content_type: message_attributes[:content_type].presence || :text,
      content: message_attributes[:content],
      source_id: "chatring:#{turn.outbound_commit.outcome_type}:#{idempotency_key}",
      content_attributes: {
        'chatring_citations' => ChatRing::Brain::VisitorCitationPresenter.call(turn)
      }
    )
  end
end
