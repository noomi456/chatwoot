class Conversations::AgentBotConditionalHumanRouteService
  Result = Data.define(:conversation, :message, :handed_off, :idempotent, :reason)
  CALLBACK_COPY = {
    'outside_business_hours' =>
      'Our team is currently outside business hours. Please leave your preferred callback time here, and a human can follow up in this conversation.',
    'no_eligible_agent_online' =>
      'Our team is currently unavailable. Please leave your preferred callback time here, and a human can follow up in this conversation.',
    'no_eligible_agent_assignable' =>
      'We could not connect you to an available human right now. ' \
      'Please leave your preferred callback time here, and a human can follow up in this conversation.',
    'agent_availability_unavailable' =>
      'We could not confirm a human is available right now. ' \
      'Please leave your preferred callback time here, and a human can follow up in this conversation.'
  }.freeze
  AUTHORIZATION_RESULTS = {
    'outside_business_hours' => 'authorized_human_outside_hours',
    'no_eligible_agent_online' => 'authorized_human_unavailable',
    'no_eligible_agent_assignable' => 'authorized_human_assignment_unavailable',
    'agent_availability_unavailable' => 'authorized_human_availability_unknown'
  }.freeze

  def initialize(turn:, outbound_commit:)
    @turn = turn
    @outbound_commit = outbound_commit
  end

  def perform
    result = commit_inside_serialization_boundary
    ChatRing::HumanRouting::NativeAssignmentAccountant.call(turn: turn, result: result)
    if result.reason&.start_with?('rejected:')
      raise Conversations::AgentBotConditionalCommitService::PreconditionFailed, result.reason.delete_prefix('rejected:')
    end

    result
  end

  private

  attr_reader :turn, :outbound_commit

  def commit_inside_serialization_boundary
    ActiveRecord::Base.transaction do
      Inbox.lock.find(turn.conversation.inbox_id)
      conversation = Conversation.lock.find(turn.chatwoot_conversation_id)
      turn.lock!
      execution = lock_playbook_execution
      outbound_commit.lock!
      validate_ledger!(conversation)
      if outbound_commit.status_committed?
        existing_result(conversation)
      elsif outbound_commit.status_rejected?
        rejected_result(conversation, outbound_commit.failure_code)
      else
        commit_route(conversation, execution)
      end
    end
  end

  def commit_route(conversation, execution)
    eligibility = ChatRing::Brain::Eligibility.check(turn)
    return reject_route(conversation, execution, eligibility.reason) unless eligibility.eligible

    availability = ChatRing::HumanRouting::NativeAvailability.check(conversation)
    return commit_native_assignment(conversation, availability) if availability.available

    commit_unavailable_fallback(conversation, execution, availability.reason)
  end

  def commit_native_assignment(conversation, availability)
    assigned_agent = Conversations::AssignmentService.new(
      conversation: conversation,
      assignee_id: availability.assignee_id
    ).perform
    conversation.reload
    unless assigned_agent && conversation.assignee_id == availability.assignee_id && conversation.assignee_agent_bot_id.nil?
      raise ActiveRecord::RecordInvalid, conversation
    end

    commit_ledger(message: nil)
    record_routing_outcome('native_assignment', assigned_agent_id: assigned_agent.id)
    Result.new(conversation: conversation, message: nil, handed_off: true, idempotent: false, reason: nil)
  end

  def commit_unavailable_fallback(conversation, execution, availability_reason)
    tool_execution = build_appointment_execution(availability_reason)
    content = tool_execution&.rendered_content || CALLBACK_COPY.fetch(availability_reason)
    message = create_message(conversation, content)
    tool_execution&.mark_committed!(timestamp: Time.current)
    action = tool_execution ? 'human_unavailable_appointment_offered' : 'human_unavailable_callback_requested'
    finalize_execution(execution, conversation, availability_reason, :stopped, action)
    commit_ledger(message: message)
    record_routing_outcome(action)
    Result.new(
      conversation: conversation,
      message: message,
      handed_off: false,
      idempotent: false,
      reason: availability_reason
    )
  end

  def build_appointment_execution(availability_reason)
    authorization = ChatRing::Tools::RequestAppointmentAuthorization.call(
      turn,
      presentation_context: availability_reason
    )
    ChatRing::Tools::RequestAppointmentExecutionBuilder.call(
      turn: turn,
      outbound_commit: outbound_commit,
      authorization: authorization,
      arguments: { 'reason_code' => 'human_unavailable' },
      authorization_result: AUTHORIZATION_RESULTS.fetch(availability_reason)
    )
  rescue ChatRing::Tools::OutcomePreparer::Rejected
    nil
  end

  def create_message(conversation, content)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      sender: turn.expected_agent_bot,
      message_type: :outgoing,
      content_type: :text,
      content: content,
      source_id: "chatring:human_route:#{outbound_commit.idempotency_key}",
      content_attributes: { 'chatring_citations' => [] }
    )
  end

  def commit_ledger(message:)
    outbound_commit.update!(
      status: :committed,
      chatwoot_message_id: message&.id,
      attempted_at: Time.current,
      committed_at: Time.current,
      failure_code: nil
    )
  end

  def record_routing_outcome(outcome, assigned_agent_id: nil)
    attributes = { 'routing_outcome' => outcome, 'assigned_agent_id' => assigned_agent_id }.compact
    turn.update!(decision_payload: turn.decision_payload.to_h.merge(attributes))
  end

  def reject_route(conversation, execution, failure_code)
    outbound_commit.update!(status: :rejected, attempted_at: Time.current, failure_code: failure_code)
    ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
      turn: turn,
      execution: execution,
      conversation: conversation,
      failure_code: failure_code
    )
    rejected_result(conversation, failure_code)
  end

  def finalize_execution(execution, conversation, failure_code, status, action)
    ChatRing::Playbooks::ExecutionFinalizer.apply_locked!(
      turn: turn,
      execution: execution,
      conversation: conversation,
      failure_code: failure_code,
      forced_outcome: [status, action]
    )
  end

  def existing_result(conversation)
    message = outbound_commit.message
    Result.new(
      conversation: conversation,
      message: message,
      handed_off: message.nil?,
      idempotent: true,
      reason: nil
    )
  end

  def rejected_result(conversation, failure_code)
    Result.new(
      conversation: conversation,
      message: nil,
      handed_off: false,
      idempotent: true,
      reason: "rejected:#{failure_code.presence || 'commit_rejected'}"
    )
  end

  def lock_playbook_execution
    return unless turn.inbox_playbook_execution_id

    ChatRing::InboxPlaybookExecution.lock.find(turn.inbox_playbook_execution_id)
  end

  def validate_ledger!(conversation)
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless outbound_commit.ai_turn_id == turn.id
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless outbound_commit.outcome_type_human_route?
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless turn.chatwoot_conversation_id == conversation.id
    raise Conversations::AgentBotConditionalCommitService::Unauthorized unless turn.expected_agent_bot&.chatring_assistant?
  end
end
