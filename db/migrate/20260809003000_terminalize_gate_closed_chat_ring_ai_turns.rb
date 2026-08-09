class TerminalizeGateClosedChatRingAiTurns < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE chat_ring_ai_turns AS turns
      SET status = 10,
          failure_code = 'public_response_gate_closed',
          completed_at = COALESCE(turns.completed_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      WHERE turns.status = 0
        AND turns.started_at IS NULL
        AND turns.native_handling_snapshot <> '{}'::jsonb
        AND NOT EXISTS (
          SELECT 1
          FROM chat_ring_outbound_commits AS commits
          WHERE commits.ai_turn_id = turns.id
            AND commits.status = 1
        )
    SQL
  end

  def down; end
end
