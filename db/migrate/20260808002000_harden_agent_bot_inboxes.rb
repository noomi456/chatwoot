class HardenAgentBotInboxes < ActiveRecord::Migration[7.1]
  DATA_CHECKS = {
    incomplete: <<~SQL.squish,
      SELECT COUNT(*)
      FROM agent_bot_inboxes
      WHERE inbox_id IS NULL OR agent_bot_id IS NULL OR account_id IS NULL OR status IS NULL
    SQL
    duplicate_inboxes: <<~SQL.squish,
      SELECT COUNT(*)
      FROM (
        SELECT inbox_id
        FROM agent_bot_inboxes
        GROUP BY inbox_id
        HAVING COUNT(*) > 1
      ) duplicates
    SQL
    orphaned: <<~SQL.squish,
      SELECT COUNT(*)
      FROM agent_bot_inboxes connections
      LEFT JOIN inboxes ON inboxes.id = connections.inbox_id
      LEFT JOIN agent_bots ON agent_bots.id = connections.agent_bot_id
      LEFT JOIN accounts ON accounts.id = connections.account_id
      WHERE inboxes.id IS NULL OR agent_bots.id IS NULL OR accounts.id IS NULL
    SQL
    inbox_account_mismatch: <<~SQL.squish,
      SELECT COUNT(*)
      FROM agent_bot_inboxes connections
      INNER JOIN inboxes ON inboxes.id = connections.inbox_id
      WHERE connections.account_id IS DISTINCT FROM inboxes.account_id
    SQL
    agent_bot_account_mismatch: <<~SQL.squish
      SELECT COUNT(*)
      FROM agent_bot_inboxes connections
      INNER JOIN agent_bots ON agent_bots.id = connections.agent_bot_id
      WHERE agent_bots.account_id IS NOT NULL
        AND connections.account_id IS DISTINCT FROM agent_bots.account_id
    SQL
  }.freeze

  def up
    assert_existing_rows_are_safe!

    change_column_null :agent_bot_inboxes, :inbox_id, false
    change_column_null :agent_bot_inboxes, :agent_bot_id, false
    change_column_null :agent_bot_inboxes, :account_id, false
    change_column_null :agent_bot_inboxes, :status, false

    add_index :agent_bot_inboxes, :inbox_id, unique: true
    add_index :agent_bot_inboxes, :agent_bot_id
    add_index :agent_bot_inboxes, :account_id

    add_foreign_key :agent_bot_inboxes, :inboxes, on_delete: :cascade
    add_foreign_key :agent_bot_inboxes, :agent_bots, on_delete: :cascade
    add_foreign_key :agent_bot_inboxes, :accounts, on_delete: :cascade
  end

  def down
    remove_foreign_key :agent_bot_inboxes, :accounts
    remove_foreign_key :agent_bot_inboxes, :agent_bots
    remove_foreign_key :agent_bot_inboxes, :inboxes

    remove_index :agent_bot_inboxes, :account_id
    remove_index :agent_bot_inboxes, :agent_bot_id
    remove_index :agent_bot_inboxes, :inbox_id

    change_column_null :agent_bot_inboxes, :status, true
    change_column_null :agent_bot_inboxes, :account_id, true
    change_column_null :agent_bot_inboxes, :agent_bot_id, true
    change_column_null :agent_bot_inboxes, :inbox_id, true
  end

  private

  def assert_existing_rows_are_safe!
    problems = DATA_CHECKS.transform_values { |sql| count(sql) }.reject { |_name, value| value.zero? }

    return if problems.empty?

    raise ActiveRecord::MigrationError,
          "agent_bot_inboxes must be audited before constraints are added: #{problems.to_json}"
  end

  def count(sql)
    connection.select_value(sql).to_i
  end
end
