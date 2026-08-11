class ChatRing::Tools::RequestAppointmentAuthorization
  Result = Data.define(:policy_version, :capability, :renderer_result)

  def self.call(turn, enforce_playbook_allowlist: false, presentation_context: nil, playbook_step_id: nil)
    new(
      turn,
      enforce_playbook_allowlist: enforce_playbook_allowlist,
      presentation_context: presentation_context,
      playbook_step_id: playbook_step_id
    ).call
  end

  def initialize(turn, enforce_playbook_allowlist:, presentation_context:, playbook_step_id:)
    @turn = turn
    @enforce_playbook_allowlist = enforce_playbook_allowlist
    @presentation_context = presentation_context
    @playbook_step_id = playbook_step_id
  end

  def call
    validate_grant!
    validate_playbook_allowlist!
    version = current_policy_version
    capability = available_capability(version)
    result(version, capability)
  rescue ChatRing::Tools::GrantSet::Invalid
    reject!('tool_grants_invalid')
  end

  private

  attr_reader :turn, :enforce_playbook_allowlist, :presentation_context, :playbook_step_id

  def grant_set
    ChatRing::Tools::GrantSet.new(turn.assistant_version.tool_grants)
  end

  def validate_grant!
    reject!('tool_not_granted') unless grant_set.include?('request_appointment', 1)
  end

  def validate_playbook_allowlist!
    reject!('tool_not_allowed_by_playbook') unless playbook_allows_tool?
  end

  def current_policy_version
    reject!('tool_policy_unavailable') if policy&.current_version.blank?

    policy.current_version
  end

  def available_capability(version)
    capability = ChatRing::Tools::InboxCapabilityProfile.new(
      inbox: turn.conversation.inbox,
      policy_version: version
    ).fetch('request_appointment', 1)
    reject!(capability.reason || 'tool_renderer_unavailable') unless capability.available
    capability
  end

  def result(version, capability)
    Result.new(
      policy_version: version,
      capability: capability,
      renderer_result: ChatRing::Tools::RequestAppointmentRenderer.call(
        version,
        presentation_context: presentation_context
      )
    )
  end

  def policy
    @policy ||= ChatRing::InboxToolPolicy.active.includes(:current_version).find_by(
      workspace_id: turn.workspace_id,
      chatwoot_inbox_id: turn.conversation.inbox_id
    )
  end

  def playbook_allows_tool?
    return true unless enforce_playbook_allowlist && turn.inbox_playbook_execution_id

    projection = ChatRing::Playbooks::InvocationProjection.new(turn, step_id: playbook_step_id)
    Array(projection.tool_allowlist).any? do |item|
      attributes = item.to_h.deep_stringify_keys
      attributes['key'] == 'request_appointment' && attributes['version'].to_i == 1
    end
  end

  def reject!(code)
    raise ChatRing::Tools::OutcomePreparer::Rejected, code
  end
end
