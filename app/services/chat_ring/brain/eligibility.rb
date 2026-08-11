class ChatRing::Brain::Eligibility
  Result = Data.define(:eligible, :reason)

  def self.check(turn, enforce_deadline: true)
    new(turn, enforce_deadline: enforce_deadline).check
  end

  def initialize(turn, enforce_deadline: true)
    @turn = turn
    @enforce_deadline = enforce_deadline
  end

  def check
    reason = runtime_failure || deadline_failure || configuration_failure || freshness_failure || ownership_failure || playbook_failure
    Result.new(eligible: reason.nil?, reason: reason)
  end

  private

  attr_reader :turn, :enforce_deadline

  def runtime_failure
    return 'public_response_gate_closed' unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    return 'legacy_runtime_mode' if turn.runtime_mode_legacy?
    return 'runtime_mode_changed' if turn.runtime_mode_external? != ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
  end

  def deadline_failure
    return unless enforce_deadline

    'turn_deadline_expired' if turn.deadline_at.blank? || turn.deadline_at <= Time.current
  end

  def configuration_failure
    return 'workspace_inactive' unless turn.workspace.status == 'active'
    return binding_failure if binding_failure
    return assistant_failure if assistant_failure
    return policy_failure if policy_failure
    return template_effect_failure if template_effect_failure

    automation_failure
  end

  def binding_failure
    return 'binding_inactive' unless turn.inbox_assistant_binding.active?
    return 'binding_version_changed' unless turn.inbox_assistant_binding.binding_version == turn.binding_version
  end

  def assistant_failure
    return 'assistant_inactive' unless turn.assistant.active?
    return 'assistant_version_changed' unless turn.assistant.current_version_id == turn.assistant_version_id
  end

  def policy_failure
    return 'unsupported_audience_policy' if turn.assistant_version.audience_policy.present?
    return 'unsupported_availability_policy' if turn.assistant_version.availability_policy.present?
  end

  def ownership_failure
    conversation = turn.conversation
    return 'unsupported_channel' unless conversation.inbox.channel_type == 'Channel::WebWidget'
    return 'conversation_not_pending' unless conversation.pending?
    return 'unexpected_agent_bot' unless conversation.assignee_agent_bot_id == turn.expected_agent_bot_id
    return 'inbox_connection_inactive' unless AgentBotInbox.active.exists?(
      inbox_id: conversation.inbox_id,
      agent_bot_id: turn.expected_agent_bot_id
    )
  end

  def playbook_failure
    execution = turn.inbox_playbook_execution
    return unless execution
    return 'playbook_execution_terminal' unless execution.status.in?(ChatRing::InboxPlaybookExecution::CONTROLLING_STATUSES)
    return 'playbook_execution_changed' unless execution.lock_version == turn.playbook_execution_lock_version
    return 'playbook_step_changed' unless execution.current_step_id == turn.playbook_step_id
    return 'playbook_newer_customer_message' unless execution.last_trigger_message_id == turn.trigger_message_id
  end

  def automation_conflict?
    ChatRing::AutomationConflictClassifier.new(
      account: turn.conversation.account,
      inbox: turn.conversation.inbox
    ).conflicting?
  end

  def automation_effect_failure
    return unless turn.runtime_mode_internal?

    ChatRing::NativeHandling::AutomationEffectPolicy.terminal_reason(
      turn.native_handling_snapshot['automation']
    )
  end

  def template_effect_failure
    return unless turn.runtime_mode_internal?

    ChatRing::NativeHandling::TemplateEffectPolicy.terminal_reason(turn.native_handling_snapshot)
  end

  def automation_failure
    automation_effect_failure || ('automation_conflict' if automation_conflict?)
  end

  def freshness_failure
    messages = turn.conversation.messages
    newest = messages
             .where(message_type: :incoming, private: false, sender_type: 'Contact')
             .reorder(id: :desc)
             .first
    return 'newer_customer_message' unless newest&.id == turn.trigger_message_id

    newer_human_reply = messages.where('id > ?', turn.trigger_message_id).any?(&:public_human_reply?)
    'newer_human_reply' if newer_human_reply
  end
end
