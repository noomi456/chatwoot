class DisableChatRingManagedAgentBotWebhooks < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE agent_bots
      SET outgoing_url = NULL, updated_at = CURRENT_TIMESTAMP
      WHERE bot_type = 1 AND outgoing_url IS NOT NULL
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'managed ChatRing AgentBot self-webhook URLs must not be restored'
  end
end
