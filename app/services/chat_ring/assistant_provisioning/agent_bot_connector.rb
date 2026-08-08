class ChatRing::AssistantProvisioning::AgentBotConnector
  class OwnershipError < StandardError; end

  class ConflictError < StandardError
    attr_reader :conflicts

    def initialize(conflicts)
      @conflicts = conflicts
      super("inbox has conflicting responders: #{conflicts.map(&:kind).join(', ')}")
    end
  end

  def initialize(workspace:, inbox:, agent_bot:, replace_agent_bot_id: nil)
    @workspace = workspace
    @inbox = inbox
    @agent_bot = agent_bot
    @replace_agent_bot_id = replace_agent_bot_id
  end

  def call
    inbox.with_lock { call_with_lock! }
  end

  # Used by the versioned binding activator while it owns the Inbox row lock.
  def call_with_lock!
    validate_ownership!
    conflicts = blocking_conflicts
    raise ConflictError, conflicts if conflicts.any?

    connection = AgentBotInbox.find_or_initialize_by(inbox_id: inbox.id)
    connection.assign_attributes(account_id: workspace.chatwoot_account_id, agent_bot: agent_bot, status: :active)
    connection.save!
    connection
  end

  private

  attr_reader :workspace, :inbox, :agent_bot, :replace_agent_bot_id

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

  def blocking_conflicts
    conflict_detector.call.reject do |conflict|
      next false unless conflict.kind == :agent_bot && replace_agent_bot_id.present?

      AgentBotInbox.find_by(id: conflict.record_id)&.agent_bot_id == replace_agent_bot_id
    end
  end
end
