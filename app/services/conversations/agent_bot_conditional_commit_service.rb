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
    @message_attributes = options.fetch(:message).to_h.symbolize_keys.slice(:content, :content_type, :content_attributes)
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
    outbound_reference = ChatRing::OutboundCommit.find_by!(idempotency_key: idempotency_key)
    result = nil
    ActiveRecord::Base.transaction do
      Inbox.lock.find(conversation.inbox_id)
      @locked_conversation = Conversation.lock.find(conversation.id)
      begin
        turn, playbook_execution, outbound_commit = lock_commit_records(outbound_reference)
        validate_ledger!(outbound_commit, turn)
        @idempotent = outbound_commit.status_committed?
        result = if outbound_commit.status_committed?
                   outbound_commit
                 else
                   commit_or_reject(outbound_commit, turn, playbook_execution)
                 end
      ensure
        @locked_conversation = nil
      end
    end
    result
  end

  def lock_commit_records(outbound_reference)
    turn = ChatRing::AiTurn.lock.find(outbound_reference.ai_turn_id)
    playbook_execution = lock_playbook_execution(turn)
    outbound_commit = ChatRing::OutboundCommit.lock.find(outbound_reference.id)
    [turn, playbook_execution, outbound_commit]
  end

  def validate_ledger!(outbound_commit, turn)
    raise Unauthorized unless outbound_commit.ai_turn_id == turn.id
    raise Unauthorized unless outbound_commit.outcome_type_reply? || outbound_commit.outcome_type_tool?
    raise Unauthorized unless turn.chatwoot_conversation_id == conversation.id
    raise Unauthorized unless turn.expected_agent_bot_id == agent_bot.id
  end

  def commit_or_reject(outbound_commit, turn, playbook_execution)
    playbook_effect = build_playbook_effect(outbound_commit, turn, playbook_execution)
    native_failure = native_precondition_failure(outbound_commit, turn)
    return reject(outbound_commit, native_failure, turn, playbook_execution) if native_failure

    playbook_failure = playbook_effect&.failure_code
    return reject(outbound_commit, playbook_failure, turn, playbook_execution) if playbook_failure

    effective_attributes = playbook_effect&.message_attributes || message_attributes
    failure_code = effect_precondition_failure(outbound_commit, turn, effective_attributes)
    return reject(outbound_commit, failure_code, turn, playbook_execution) if failure_code

    message = create_message(turn, outbound_commit, effective_attributes)
    playbook_effect&.apply!(message)
    outbound_commit.update!(
      status: :committed,
      chatwoot_message_id: message.id,
      attempted_at: Time.current,
      committed_at: Time.current,
      failure_code: nil
    )
    tool_execution_for(turn)&.mark_committed!(timestamp: outbound_commit.committed_at)
    outbound_commit
  end

  def lock_playbook_execution(turn)
    return unless turn.inbox_playbook_execution_id

    ChatRing::InboxPlaybookExecution.lock.find(turn.inbox_playbook_execution_id)
  end

  def build_playbook_effect(outbound_commit, turn, execution)
    return unless outbound_commit.outcome_type_reply? && execution
    return unless ChatRing::Playbooks::CommitEffect.applicable?(turn)

    ChatRing::Playbooks::CommitEffect.new(turn: turn, execution: execution)
  end

  def native_precondition_failure(outbound_commit, turn)
    return outbound_failure(outbound_commit: outbound_commit) if outbound_commit.status_rejected?
    return 'invalid_trigger_message' unless valid_trigger_message?(turn)

    eligibility = ChatRing::Brain::Eligibility.check(turn)
    eligibility.reason unless eligibility.eligible
  end

  def effect_precondition_failure(outbound_commit, turn, effective_attributes)
    return 'invalid_message' unless valid_message_payload?(effective_attributes)

    execution = tool_execution_for(turn)
    return unless outbound_commit.outcome_type_tool? || execution

    tool_eligibility = ChatRing::Tools::CommitEligibility.check(execution: execution, turn: turn)
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

  def valid_message_payload?(attributes)
    attributes[:content].to_s.strip.present? && (attributes[:content_type].presence || 'text').to_s == 'text'
  end

  def reject(outbound_commit, failure_code, turn, playbook_execution)
    outbound_commit.update!(status: :rejected, attempted_at: Time.current, failure_code: failure_code)
    tool_execution_for(turn)&.mark_rejected!(failure_code)
    ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
      turn: turn,
      execution: playbook_execution,
      conversation: conversation,
      failure_code: failure_code
    )
    outbound_commit
  end

  def create_message(turn, _outbound_commit, attributes) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    microsite = ChatRing::Microsites::ArtifactBuilder.call(turn)
    content_attributes = {
      'chatring_citations' => ChatRing::Brain::VisitorCitationPresenter.call(turn)
    }
    suggestions = Array(turn.decision_payload['suggested_questions']).first(ChatRing::Brain::Decision::MAX_SUGGESTED_QUESTIONS)
    content_attributes['chatring_suggestions'] = suggestions if suggestions.present?
    response_options = Array(turn.decision_payload['response_options']).first(ChatRing::Brain::Decision::MAX_RESPONSE_OPTIONS)
    if response_options.present?
      content_attributes['chatring_response_options'] = response_options.map { |option| { 'label' => option, 'value' => option } }
    end
    execution = tool_execution_for(turn)
    content_attributes['chatring_tool'] = tool_presentation(execution) if execution
    content_attributes['chatring_microsite'] = ChatRing::Microsites::VisitorPresentation.call(microsite) if microsite
    content_attributes.merge!(safe_playbook_content_attributes(attributes))

    message = conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: agent_bot,
      message_type: :outgoing,
      content_type: attributes[:content_type].presence || :text,
      content: attributes[:content],
      source_id: "chatring:#{turn.outbound_commit.outcome_type}:#{idempotency_key}",
      content_attributes: content_attributes
    )
    microsite&.update!(message: message)
    message
  end

  def tool_presentation(tool_execution)
    ChatRing::Tools::VisitorPresentation.call(tool_execution)
  rescue ArgumentError
    raise Unauthorized
  end

  def tool_execution_for(turn)
    ChatRing::ToolExecution.find_by(ai_turn_id: turn.id)
  end

  def safe_playbook_content_attributes(attributes)
    attributes.fetch(:content_attributes, {}).to_h.stringify_keys.slice('chatring_playbook_options')
  end
end
