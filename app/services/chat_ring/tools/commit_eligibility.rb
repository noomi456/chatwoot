class ChatRing::Tools::CommitEligibility
  Result = Data.define(:eligible, :reason)

  def self.check(execution:, turn:)
    new(execution: execution, turn: turn).check
  end

  def initialize(execution:, turn:)
    @execution = execution
    @turn = turn
  end

  def check
    failure_code = record_failure || grant_failure || policy_failure || capability_failure
    return rejected(failure_code) if failure_code

    Result.new(eligible: true, reason: nil)
  rescue ChatRing::Tools::GrantSet::Invalid, KeyError, ArgumentError
    rejected('tool_authorization_invalid')
  end

  private

  attr_reader :execution, :turn

  def record_failure
    return 'tool_execution_missing' unless execution
    return 'tool_execution_not_pending' unless execution.status_pending?
    return 'tool_execution_mismatch' unless execution.ai_turn_id == turn.id
    return 'tool_outcome_mismatch' unless execution.outbound_commit_id == turn.outbound_commit&.id
  end

  def grant_failure
    definition = tool_definition
    grants = ChatRing::Tools::GrantSet.new(turn.assistant_version.tool_grants)
    return 'tool_not_granted' unless grants.include?(definition.key, definition.version)
  end

  def policy_failure
    return 'tool_policy_scope_changed' unless policy_scope_matches?(policy)
    return 'tool_policy_inactive' unless policy.active?
    return 'tool_policy_changed' unless policy.current_version_id == policy_version.id
  end

  def capability_failure
    capability = capability_profile.fetch(tool_definition.key, tool_definition.version)
    return capability.reason || 'tool_renderer_unavailable' unless capability.available
    return 'tool_renderer_changed' unless capability.renderer == execution.renderer
    return 'tool_result_changed' unless rendered_result_matches?(policy_version)
  end

  def tool_definition
    @tool_definition ||= ChatRing::Tools::Registry.fetch(execution.tool_key, execution.tool_version)
  end

  def policy_version
    @policy_version ||= execution.inbox_tool_policy_version
  end

  def policy
    @policy ||= policy_version.inbox_tool_policy
  end

  def capability_profile
    @capability_profile ||= ChatRing::Tools::InboxCapabilityProfile.new(
      inbox: turn.conversation.inbox,
      policy_version: policy_version
    )
  end

  def policy_scope_matches?(policy)
    policy.workspace_id == turn.workspace_id && policy.chatwoot_inbox_id == turn.conversation.inbox_id
  end

  def rendered_result_matches?(policy_version)
    return false unless execution.tool_key == 'request_appointment'

    result = ChatRing::Tools::RequestAppointmentRenderer.call(
      policy_version,
      presentation_context: ChatRing::Tools::RequestAppointmentRenderer.presentation_context(execution.authorization_result)
    )
    execution.rendered_content == result.content && execution.result_payload == result.payload
  end

  def rejected(reason)
    Result.new(eligible: false, reason: reason)
  end
end
