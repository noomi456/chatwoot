class CreateChatRingBrainRecords < ActiveRecord::Migration[7.1]
  def change
    add_assistant_model_configuration
    add_turn_decision_fields
    create_ai_turn_attempts
    create_ai_turn_evidence
  end

  private

  def add_assistant_model_configuration
    add_column :chat_ring_assistant_versions, :llm_provider, :string, null: false, default: 'openai'
    add_column :chat_ring_assistant_versions, :llm_model, :string, null: false, default: 'gpt-4.1-mini'
  end

  def add_turn_decision_fields
    add_column :chat_ring_ai_turns, :knowledge_index_id, :bigint
    add_column :chat_ring_ai_turns, :context_digest, :string
    add_column :chat_ring_ai_turns, :decision_payload, :jsonb, null: false, default: {}
    add_foreign_key :chat_ring_ai_turns,
                    :chat_ring_knowledge_indexes,
                    column: :knowledge_index_id,
                    on_delete: :restrict
    add_index :chat_ring_ai_turns, :knowledge_index_id
  end

  def create_ai_turn_attempts # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_ai_turn_attempts do |t|
      t.references :ai_turn,
                   null: false,
                   foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :cascade }
      t.integer :attempt_number, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.integer :status, null: false, default: 0
      t.string :request_digest, null: false
      t.string :response_digest
      t.integer :input_tokens
      t.integer :output_tokens
      t.string :failure_code
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :chat_ring_ai_turn_attempts,
              [:ai_turn_id, :attempt_number],
              unique: true,
              name: 'idx_chatring_turn_attempts_unique'
  end

  def create_ai_turn_evidence # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_ai_turn_evidence do |t|
      t.references :ai_turn,
                   null: false,
                   foreign_key: { to_table: :chat_ring_ai_turns, on_delete: :cascade }
      t.integer :position, null: false
      t.string :evidence_id, null: false
      t.bigint :knowledge_index_id
      t.string :provider_source_id
      t.string :provider_chunk_id
      t.string :source_kind, null: false
      t.string :source_reference, null: false
      t.string :source_title, null: false
      t.string :public_url
      t.jsonb :heading_path, null: false, default: []
      t.text :excerpt, null: false
      t.string :source_content_hash, null: false
      t.integer :rank, null: false
      t.decimal :score, precision: 12, scale: 8, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_foreign_key :chat_ring_ai_turn_evidence,
                    :chat_ring_knowledge_indexes,
                    column: :knowledge_index_id,
                    on_delete: :restrict
    add_index :chat_ring_ai_turn_evidence,
              [:ai_turn_id, :position],
              unique: true,
              name: 'idx_chatring_turn_evidence_position'
    add_index :chat_ring_ai_turn_evidence, :evidence_id
  end
end
