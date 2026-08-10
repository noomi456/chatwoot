class RejectGateClosedPendingChatRingOutcomes < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE chat_ring_outbound_commits AS commits
      SET status = 2,
          failure_code = 'public_response_gate_closed',
          attempted_at = COALESCE(commits.attempted_at, CURRENT_TIMESTAMP),
          updated_at = CURRENT_TIMESTAMP
      FROM chat_ring_ai_turns AS turns
      WHERE turns.id = commits.ai_turn_id
        AND turns.status = 10
        AND turns.failure_code = 'public_response_gate_closed'
        AND commits.status = 0
    SQL
  end

  def down
    # A rejected customer outcome must never be made pending by rollback.
  end
end
