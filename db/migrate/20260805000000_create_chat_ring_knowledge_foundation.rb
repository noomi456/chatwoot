class CreateChatRingKnowledgeFoundation < ActiveRecord::Migration[7.1]
  # This migration intentionally defines the complete versioned knowledge
  # boundary in one reversible DDL transaction.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def change
    create_table :chat_ring_knowledge_versions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.string :status, null: false, default: 'pending'
      t.string :provider, null: false, default: 'docs_gpt'
      t.string :provider_release, null: false
      t.string :root_url, null: false
      t.datetime :firecrawl_start_started_at
      t.string :firecrawl_crawl_id
      t.jsonb :mapped_manifest, null: false, default: []
      t.string :manifest_digest
      t.jsonb :crawl_errors, null: false, default: []
      t.jsonb :config_snapshot, null: false, default: {}
      t.string :provider_agent_id
      t.text :provider_agent_api_key
      t.datetime :provider_agent_creation_started_at
      t.string :failure_code
      t.text :failure_message
      t.datetime :ready_at
      t.datetime :published_at

      t.timestamps
    end

    add_index :chat_ring_knowledge_versions, [:account_id, :inbox_id, :created_at],
              name: 'index_chatring_knowledge_versions_on_scope_and_created_at'
    add_index :chat_ring_knowledge_versions, :firecrawl_crawl_id,
              unique: true, where: 'firecrawl_crawl_id IS NOT NULL'
    add_check_constraint :chat_ring_knowledge_versions,
                         "status IN ('pending', 'crawling', 'ingesting', 'ready', 'published', 'retired', 'failed')",
                         name: 'chatring_knowledge_versions_status_check'

    create_table :chat_ring_knowledge_documents do |t|
      t.references :knowledge_version,
                   null: false,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { name: 'index_chatring_knowledge_documents_on_version_id' }
      t.string :source_url, null: false
      t.string :title
      t.text :markdown, null: false
      t.string :content_hash, null: false
      t.string :provider_file_name, null: false
      t.string :provider_task_id
      t.string :provider_source_id
      t.string :provider_source_reference
      t.string :provider_status, null: false, default: 'pending'
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :chat_ring_knowledge_documents, [:knowledge_version_id, :source_url],
              unique: true, name: 'index_chatring_knowledge_documents_on_version_and_url'
    add_index :chat_ring_knowledge_documents, [:knowledge_version_id, :provider_file_name],
              unique: true, name: 'index_chatring_knowledge_documents_on_version_and_file'
    add_check_constraint :chat_ring_knowledge_documents,
                         "provider_status IN ('pending', 'processing', 'ready', 'failed')",
                         name: 'chatring_knowledge_documents_provider_status_check'

    create_table :chat_ring_knowledge_publications do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.references :knowledge_version,
                   null: false,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { name: 'index_chatring_publications_on_version_id' }
      t.references :previous_knowledge_version,
                   foreign_key: { to_table: :chat_ring_knowledge_versions },
                   index: { name: 'index_chatring_publications_on_previous_version_id' }
      t.datetime :published_at, null: false

      t.timestamps
    end

    add_index :chat_ring_knowledge_publications, [:account_id, :inbox_id],
              unique: true, name: 'index_chatring_knowledge_publications_on_scope'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
