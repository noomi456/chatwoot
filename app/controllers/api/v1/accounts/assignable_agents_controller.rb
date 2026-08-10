class Api::V1::Accounts::AssignableAgentsController < Api::V1::Accounts::BaseController
  before_action :fetch_inboxes

  def index
    # TODO: Remove this opt-in once mobile clients support AgentBot assignees in this payload.
    @include_agent_bots = params[:include_agent_bots].present?
    agent_ids = @inboxes.map do |inbox|
      authorize inbox, :show?
      member_ids = inbox.members.pluck(:user_id)
      member_ids
    end
    agent_ids = agent_ids.inject(:&)
    agents = Current.account.users.where(id: agent_ids)
    @assignable_agents = (agents + Current.account.administrators).uniq
    @agent_bots = @include_agent_bots ? assignable_agent_bots : []
  end

  private

  def fetch_inboxes
    @inboxes = Current.account.inboxes.find(permitted_params[:inbox_ids])
  end

  def permitted_params
    params.permit(inbox_ids: [])
  end

  def assignable_agent_bots
    accessible = AgentBot.accessible_to(Current.account)
    external = accessible.where.not(bot_type: :chatring_assistant).to_a
    managed_agent_bot_id = shared_managed_agent_bot_id

    managed_agent_bot_id ? external + accessible.where(id: managed_agent_bot_id).to_a : external
  end

  def shared_managed_agent_bot_id
    workspace = Current.account.chat_ring_workspace
    return unless workspace

    inbox_ids = @inboxes.map(&:id)
    connected_bot_ids = ChatRing::InboxAssistantBinding.active
                                                       .joins(:assistant_agent_bot_connection)
                                                       .where(workspace_id: workspace.id, chatwoot_inbox_id: inbox_ids)
                                                       .pluck(
                                                         :chatwoot_inbox_id,
                                                         'chat_ring_assistant_agent_bot_connections.agent_bot_id'
                                                       ).to_h
    return unless connected_bot_ids.keys.sort == inbox_ids.sort

    agent_bot_ids = connected_bot_ids.values.uniq
    return unless agent_bot_ids.one?

    agent_bot_id = agent_bot_ids.first
    return unless AgentBotInbox.active.where(inbox_id: inbox_ids, agent_bot_id: agent_bot_id).count == inbox_ids.length

    agent_bot_id
  end
end
