class CreateChatRingOutboundCommits < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_ring_outbound_commits do |t|
      t.references :ai_turn,
                   null: false,
                   foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :cascade },
                   index: { unique: true }
      t.string :idempotency_key, null: false
      t.bigint :chatwoot_message_id
      t.integer :status, null: false, default: 0
      t.datetime :attempted_at
      t.datetime :committed_at
      t.string :failure_code
      t.timestamps
    end

    add_index :chat_ring_outbound_commits, :idempotency_key, unique: true
    add_foreign_key :chat_ring_outbound_commits,
                    :messages,
                    column: :chatwoot_message_id,
                    on_delete: :restrict
  end
end
