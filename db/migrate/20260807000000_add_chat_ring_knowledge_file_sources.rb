class AddChatRingKnowledgeFileSources < ActiveRecord::Migration[7.1]
  def up # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :chat_ring_knowledge_file_sources do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :inbox, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :source_key, null: false, default: -> { 'gen_random_uuid()' }
      t.string :status, null: false, default: 'uploaded'
      t.string :source_kind, null: false
      t.string :original_filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.string :raw_content_hash, null: false
      t.string :authority_class, null: false, default: 'product_documentation'
      t.jsonb :parser_profile, null: false, default: {}
      t.string :parser_profile_digest, null: false
      t.text :markdown
      t.string :content_hash
      t.jsonb :metadata, null: false, default: {}
      t.datetime :parse_started_at
      t.datetime :parsed_at
      t.datetime :disabled_at
      t.string :failure_code
      t.string :failure_message, limit: 1000
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end

    add_index :chat_ring_knowledge_file_sources, :source_key, unique: true
    add_index :chat_ring_knowledge_file_sources,
              [:account_id, :inbox_id, :raw_content_hash, :parser_profile_digest],
              unique: true,
              name: 'index_chatring_file_sources_on_scope_content_and_parser'
    add_index :chat_ring_knowledge_file_sources, [:account_id, :inbox_id, :status],
              name: 'index_chatring_file_sources_on_scope_and_status'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "status IN ('uploaded', 'parsing', 'ready', 'parse_indeterminate', 'failed', 'disabled')",
                         name: 'chatring_file_sources_status_check'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "source_kind IN ('pdf', 'docx')",
                         name: 'chatring_file_sources_kind_check'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "authority_class IN ('product_documentation', 'structured_commercial', 'marketing', " \
                         "'approved_legal_policy', 'approved_compliance')",
                         name: 'chatring_file_sources_authority_check'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         'byte_size > 0 AND byte_size <= 52428800',
                         name: 'chatring_file_sources_size_check'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "status != 'ready' OR (markdown IS NOT NULL AND content_hash IS NOT NULL AND parsed_at IS NOT NULL)",
                         name: 'chatring_file_sources_ready_snapshot_check'

    change_column_null :chat_ring_knowledge_versions, :root_url, true

    change_table :chat_ring_knowledge_documents, bulk: true do |table|
      table.string :source_kind, null: false, default: 'website'
      table.string :source_reference
      table.string :public_url
      table.change_null :source_url, true
      table.references :file_source,
                       foreign_key: { to_table: :chat_ring_knowledge_file_sources, on_delete: :nullify },
                       index: { name: 'index_chatring_knowledge_documents_on_file_source_id' }
    end
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_documents
      SET source_reference = source_url,
          public_url = source_url
      WHERE source_reference IS NULL
    SQL
    change_column_null :chat_ring_knowledge_documents, :source_reference, false
    add_index :chat_ring_knowledge_documents, [:knowledge_version_id, :source_reference],
              unique: true,
              name: 'index_chatring_documents_on_version_and_reference'
    add_check_constraint :chat_ring_knowledge_documents,
                         "source_kind IN ('website', 'pdf', 'docx')",
                         name: 'chatring_knowledge_documents_source_kind_check'
    add_check_constraint :chat_ring_knowledge_documents,
                         "source_kind != 'website' OR public_url IS NOT NULL",
                         name: 'chatring_knowledge_documents_website_url_check'
  end

  def down # rubocop:disable Metrics/MethodLength
    remove_check_constraint :chat_ring_knowledge_documents,
                            name: 'chatring_knowledge_documents_website_url_check'
    remove_check_constraint :chat_ring_knowledge_documents,
                            name: 'chatring_knowledge_documents_source_kind_check'
    remove_index :chat_ring_knowledge_documents,
                 name: 'index_chatring_documents_on_version_and_reference'
    remove_reference :chat_ring_knowledge_documents, :file_source
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_documents
      SET source_url = source_reference
      WHERE source_url IS NULL
    SQL
    change_table :chat_ring_knowledge_documents, bulk: true do |table|
      table.change_null :source_url, false
      table.remove :public_url, :source_reference, :source_kind
    end

    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_versions
      SET root_url = 'https://invalid.local/'
      WHERE root_url IS NULL
    SQL
    change_column_null :chat_ring_knowledge_versions, :root_url, false
    drop_table :chat_ring_knowledge_file_sources
  end
end
