class ChatRing::AssistantProvisioning::AgentBotConnector
  class OwnershipError < StandardError; end

  class ConflictError < StandardError
    attr_reader :conflicts

    def initialize(conflicts)
      @conflicts = conflicts
      super("inbox has conflicting responders: #{conflicts.map(&:kind).join(', ')}")
    end
  end

  def initialize(workspace:, inbox:, agent_bot:)
    @workspace = workspace
    @inbox = inbox
    @agent_bot = agent_bot
  end

  def call
    inbox.with_lock do
      validate_ownership!
      conflicts = conflict_detector.call
      raise ConflictError, conflicts if conflicts.any?

      connection = AgentBotInbox.find_or_initialize_by(inbox_id: inbox.id)
      connection.assign_attributes(account_id: workspace.chatwoot_account_id, agent_bot: agent_bot, status: :active)
      connection.save!
      connection
    end
  end

  private

  attr_reader :workspace, :inbox, :agent_bot

  def validate_ownership!
    account_id = workspace.chatwoot_account_id
    raise OwnershipError, 'workspace must be active' unless workspace.status == 'active'
    raise OwnershipError, 'inbox must belong to the workspace account' unless inbox.account_id == account_id
    raise OwnershipError, 'AgentBot must be account-owned' if agent_bot.account_id.blank?
    return if agent_bot.account_id == account_id

    raise OwnershipError, 'AgentBot must belong to the workspace account'
  end

  def conflict_detector
    ChatRing::AssistantProvisioning::InboxConflictDetector.new(
      inbox: inbox,
      expected_agent_bot_id: agent_bot.id
    )
  end
end
