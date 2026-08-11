class ChatRing::HumanRouting::NativeAssignmentAccountant
  def self.call(turn:, result:)
    return unless result.handed_off

    conversation = result.conversation
    return unless conversation.inbox.auto_assignment_v2_enabled?

    assigned_agent_id = turn.reload.decision_payload.to_h.fetch('assigned_agent_id')
    agent = conversation.account.users.find_by(id: assigned_agent_id)
    return unless agent

    AutoAssignment::AssignmentService.new(inbox: conversation.inbox).account_assignment(
      conversation: conversation,
      agent: agent
    )
  end
end
