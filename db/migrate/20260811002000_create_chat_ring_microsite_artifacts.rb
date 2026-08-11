class CreateChatRingMicrositeArtifacts < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_ring_microsite_artifacts do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.references :ai_turn, null: false, foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :cascade }
      t.references :message, null: true, type: :integer, foreign_key: { to_table: :messages, on_delete: :nullify }
      t.string :public_token, null: false
      t.integer :contract_version, null: false, default: 1
      t.jsonb :content, null: false, default: {}
      t.jsonb :source_evidence_ids, null: false, default: []
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :chat_ring_microsite_artifacts, :ai_turn_id, unique: true
    add_index :chat_ring_microsite_artifacts, :public_token, unique: true
    add_index :chat_ring_microsite_artifacts, :expires_at
  end
end
