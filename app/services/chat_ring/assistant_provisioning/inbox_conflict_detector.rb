class ChatRing::AssistantProvisioning::InboxConflictDetector
  Conflict = Struct.new(:kind, :record_id, keyword_init: true)

  def initialize(inbox:, expected_agent_bot_id: nil)
    @inbox = inbox
    @expected_agent_bot_id = expected_agent_bot_id
  end

  def call
    [agent_bot_conflict, dialogflow_conflict, captain_conflict].compact.freeze
  end

  def conflicting?
    call.any?
  end

  private

  attr_reader :inbox, :expected_agent_bot_id

  def agent_bot_conflict
    connection = AgentBotInbox.find_by(inbox_id: inbox.id)
    return unless connection&.active?
    return if connection.agent_bot_id == expected_agent_bot_id

    Conflict.new(kind: :agent_bot, record_id: connection.id)
  end

  def dialogflow_conflict
    hook = inbox.hooks.enabled.find_by(app_id: 'dialogflow')
    return if hook.blank?

    Conflict.new(kind: :dialogflow, record_id: hook.id)
  end

  # Captain is an Enterprise overlay. Querying its association table keeps the
  # CE provisioning boundary independent from Captain models and services.
  def captain_conflict
    record_id = captain_inbox_id
    return if record_id.blank?

    Conflict.new(kind: :captain, record_id: record_id)
  end

  def captain_inbox_id
    connection = ApplicationRecord.connection
    return unless connection.data_source_exists?('captain_inboxes')

    connection.select_value(<<~SQL.squish)
      SELECT id
      FROM captain_inboxes
      WHERE inbox_id = #{connection.quote(inbox.id)}
      LIMIT 1
    SQL
  end
end
