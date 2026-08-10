class AddRuntimeModeAndTerminalizeGateClosedAiTurns < ActiveRecord::Migration[7.1]
  def up
    add_column :chat_ring_ai_turns, :runtime_mode, :integer, null: false, default: 0

    mark_existing_turns_as_legacy
    reconcile_committed_turns
    cancel_uncommitted_turns
  end

  def down
    remove_column :chat_ring_ai_turns, :runtime_mode
  end

  private

  def mark_existing_turns_as_legacy
    # Every pre-migration turn predates the durable internal/external runtime
    # marker. Terminal records remain available for audit without being
    # misrepresented as current internal work.
    execute <<~SQL.squish
      UPDATE chat_ring_ai_turns
      SET runtime_mode = 2
    SQL
  end

  def reconcile_committed_turns
    execute <<~SQL.squish
      UPDATE chat_ring_ai_turns AS turns
      SET status = CASE commits.outcome_type WHEN 1 THEN 8 ELSE 5 END,
          failure_code = NULL,
          completed_at = COALESCE(turns.completed_at, commits.committed_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      FROM chat_ring_outbound_commits AS commits
      WHERE commits.ai_turn_id = turns.id
        AND commits.status = 1
        AND turns.status IN (0, 1, 2, 3, 4)
    SQL
  end

  def cancel_uncommitted_turns
    execute <<~SQL.squish
      UPDATE chat_ring_ai_turns AS turns
      SET status = 10,
          failure_code = 'public_response_gate_closed',
          completed_at = COALESCE(turns.completed_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      WHERE turns.status IN (0, 1, 2, 3, 4)
        AND NOT EXISTS (
          SELECT 1
          FROM chat_ring_outbound_commits AS commits
          WHERE commits.ai_turn_id = turns.id
            AND commits.status = 1
        )
    SQL
  end
end
