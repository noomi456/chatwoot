class ChatRing::HumanRouting::NativeAvailability
  Result = Data.define(:available, :within_business_hours, :eligible_agent_ids, :assignee_id, :reason)

  def self.check(conversation)
    new(conversation).check
  end

  def initialize(conversation)
    @conversation = conversation
  end

  def check
    within_business_hours = !inbox.out_of_office?
    return result(false, false, [], nil, 'outside_business_hours') unless within_business_hours

    return result(false, true, [], nil, 'no_eligible_agent_online') unless online_agent?

    assignee = native_assignee
    return result(false, true, [], nil, 'no_eligible_agent_assignable') unless assignee

    result(true, true, [assignee.id], assignee.id, nil)
  rescue StandardError => e
    Rails.logger.error(
      "[ChatRing] native agent availability failed inbox_id=#{inbox.id} conversation_id=#{conversation.id} error=#{e.class.name}"
    )
    result(false, within_business_hours == true, [], nil, 'agent_availability_unavailable')
  end

  private

  attr_reader :conversation

  def inbox
    conversation.inbox
  end

  def online_agent?
    agents = inbox.available_agents
    return agents.exists? if conversation.team_id.blank?

    agents.exists?(user_id: conversation.team&.members&.select(:id))
  end

  def native_assignee
    return unless inbox.enable_auto_assignment?
    return assignment_v2_assignee if inbox.auto_assignment_v2_enabled?

    AutoAssignment::AgentAssignmentService.new(
      conversation: conversation,
      allowed_agent_ids: native_allowed_agent_ids
    ).find_assignee
  end

  def assignment_v2_assignee
    AutoAssignment::AssignmentService.new(inbox: inbox).available_agent_for(conversation)
  end

  def native_allowed_agent_ids
    member_ids = inbox.member_ids_with_assignment_capacity
    return member_ids if conversation.team_id.blank?
    return [] unless conversation.team&.allow_auto_assign?

    member_ids & conversation.team.members.ids
  end

  def result(available, within_business_hours, eligible_agent_ids, assignee_id, reason)
    Result.new(
      available: available,
      within_business_hours: within_business_hours,
      eligible_agent_ids: eligible_agent_ids.freeze,
      assignee_id: assignee_id,
      reason: reason
    )
  end
end
