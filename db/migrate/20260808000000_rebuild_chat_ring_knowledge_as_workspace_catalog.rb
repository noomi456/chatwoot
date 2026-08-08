require 'digest'
require 'uri'

class RebuildChatRingKnowledgeAsWorkspaceCatalog < ActiveRecord::Migration[7.1]
  class LegacyVersion < ActiveRecord::Base
    self.table_name = 'chat_ring_knowledge_versions'
  end

  class LegacyDocument < ActiveRecord::Base
    self.table_name = 'chat_ring_knowledge_documents'
  end

  class LegacyPublication < ActiveRecord::Base
    self.table_name = 'chat_ring_knowledge_publications'
  end

  # This is a product-model cutover, not a reversible column shuffle. The old
  # per-Inbox publications cannot be reconstructed after knowledge becomes a
  # single Workspace-owned catalog.
  def down
    raise ActiveRecord::IrreversibleMigration,
          'Workspace knowledge ownership cannot be collapsed back into per-Inbox publications'
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def up
    reject_ambiguous_file_ownership!
    create_workspace_boundary
    create_material_catalog
    attach_hidden_provider_builds
    backfill_workspace_catalogs
    enforce_workspace_scope
    remove_per_inbox_publication_boundary
    rename_hidden_provider_storage
  end

  private

  def reject_ambiguous_file_ownership!
    conflicts = select_rows(<<~SQL.squish)
      SELECT account_id, raw_content_hash, parser_profile_digest, COUNT(*)
      FROM chat_ring_knowledge_file_sources
      GROUP BY account_id, raw_content_hash, parser_profile_digest
      HAVING COUNT(*) > 1
      ORDER BY account_id
    SQL
    return if conflicts.empty?

    account_ids = conflicts.map { |row| row.fetch('account_id') }.uniq.join(', ')
    raise ActiveRecord::IrreversibleMigration,
          "Accounts #{account_ids} have duplicate per-Inbox files; resolve them before Workspace cutover"
  end

  def create_workspace_boundary
    create_table :chat_ring_workspaces do |t|
      t.references :chatwoot_account,
                   null: false,
                   foreign_key: { to_table: :accounts, on_delete: :cascade },
                   index: { unique: true }
      t.string :status, null: false, default: 'active'
      t.integer :policy_version, null: false, default: 1
      t.timestamps
    end
    add_check_constraint :chat_ring_workspaces,
                         "status IN ('active', 'suspended', 'disabled')",
                         name: 'chatring_workspaces_status_check'

    create_table :chat_ring_knowledge_bases do |t|
      t.references :workspace,
                   null: false,
                   foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade },
                   index: { unique: true }
      # This pointer is an internal atomic DocsGPT index swap. It is not a
      # user-visible knowledge version or publication workflow.
      t.bigint :active_knowledge_version_id
      t.timestamps
    end
  end

  def create_material_catalog # rubocop:disable Metrics/MethodLength
    create_table :chat_ring_knowledge_website_sources do |t|
      t.references :knowledge_base, null: false, foreign_key: { to_table: :chat_ring_knowledge_bases, on_delete: :cascade }
      t.uuid :source_key, null: false, default: -> { 'gen_random_uuid()' }
      t.string :source_type, null: false, default: 'website'
      t.string :root_url, null: false
      t.string :status, null: false, default: 'mapping'
      t.uuid :extraction_token
      t.string :firecrawl_crawl_id
      t.jsonb :mapped_manifest, null: false, default: []
      t.jsonb :crawl_errors, null: false, default: []
      t.datetime :last_processed_at
      t.datetime :deleted_at
      t.string :failure_code
      t.string :failure_message, limit: 1000
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :chat_ring_knowledge_website_sources, :source_key, unique: true
    add_index :chat_ring_knowledge_website_sources, [:knowledge_base_id, :source_type, :root_url], unique: true,
              name: 'index_chatring_web_sources_on_base_type_and_url'
    add_index :chat_ring_knowledge_website_sources, :firecrawl_crawl_id, unique: true,
              where: 'firecrawl_crawl_id IS NOT NULL'
    add_check_constraint :chat_ring_knowledge_website_sources,
                         "status IN ('mapping', 'mapped', 'extracting', 'available', 'refreshing', " \
                         "'refresh_failed', 'failed', 'deleted')",
                         name: 'chatring_website_sources_status_check'
    add_check_constraint :chat_ring_knowledge_website_sources,
                         "source_type IN ('website', 'webpage')",
                         name: 'chatring_website_sources_type_check'

    create_table :chat_ring_knowledge_materials do |t|
      t.references :knowledge_base, null: false, foreign_key: { to_table: :chat_ring_knowledge_bases, on_delete: :cascade }
      t.references :website_source,
                   foreign_key: { to_table: :chat_ring_knowledge_website_sources, on_delete: :cascade }
      t.references :file_source,
                   foreign_key: { to_table: :chat_ring_knowledge_file_sources, on_delete: :cascade }
      t.uuid :material_key, null: false, default: -> { 'gen_random_uuid()' }
      t.string :source_kind, null: false
      t.string :source_reference, null: false
      t.string :title
      t.string :public_url
      t.string :status, null: false, default: 'processing'
      t.text :markdown
      t.string :content_hash
      t.string :authority_class, null: false, default: 'product_documentation'
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :risk_flags, null: false, default: []
      t.datetime :extracted_at
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :chat_ring_knowledge_materials, :material_key, unique: true
    add_index :chat_ring_knowledge_materials, [:knowledge_base_id, :source_reference], unique: true,
              name: 'index_chatring_materials_on_base_and_reference'
    add_index :chat_ring_knowledge_materials, [:knowledge_base_id, :deleted_at],
              name: 'index_chatring_materials_on_base_and_deletion'
    add_check_constraint :chat_ring_knowledge_materials,
                         "source_kind IN ('website', 'pdf', 'docx', 'doc', 'odt', 'rtf', 'xlsx', 'xls', 'html')",
                         name: 'chatring_materials_source_kind_check'
    add_check_constraint :chat_ring_knowledge_materials,
                         "status IN ('processing', 'available', 'updating', 'refresh_failed', 'failed')",
                         name: 'chatring_materials_status_check'
    add_check_constraint :chat_ring_knowledge_materials,
                         '((website_source_id IS NOT NULL)::integer + (file_source_id IS NOT NULL)::integer) = 1',
                         name: 'chatring_materials_exactly_one_source_check'
    add_check_constraint :chat_ring_knowledge_materials,
                         "source_kind != 'website' OR public_url IS NOT NULL",
                         name: 'chatring_materials_website_url_check'

    # Assistant scopes are modeled now even though Phase 2A only creates the
    # default business-wide scope. Phase 2B can restrict the canonical catalog
    # without copying knowledge per Assistant.
    create_table :chat_ring_knowledge_scopes do |t|
      t.references :workspace, null: false, foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
      t.string :name, null: false
      t.boolean :business_wide, null: false, default: false
      t.timestamps
    end
    add_index :chat_ring_knowledge_scopes, [:workspace_id, :name], unique: true
    add_index :chat_ring_knowledge_scopes, :workspace_id, unique: true,
              where: 'business_wide = TRUE', name: 'index_chatring_scopes_on_business_wide_workspace'

    create_table :chat_ring_knowledge_scope_materials do |t|
      t.references :knowledge_scope, null: false, foreign_key: { to_table: :chat_ring_knowledge_scopes, on_delete: :cascade }
      t.references :knowledge_material, null: false, foreign_key: { to_table: :chat_ring_knowledge_materials, on_delete: :cascade }
      t.string :access, null: false
      t.timestamps
    end
    add_index :chat_ring_knowledge_scope_materials, [:knowledge_scope_id, :knowledge_material_id], unique: true,
              name: 'index_chatring_scope_materials_on_scope_and_material'
    add_check_constraint :chat_ring_knowledge_scope_materials,
                         "access IN ('allow', 'deny')",
                         name: 'chatring_scope_materials_access_check'
  end

  def attach_hidden_provider_builds
    add_reference :chat_ring_knowledge_versions, :workspace,
                  foreign_key: { to_table: :chat_ring_workspaces, on_delete: :cascade }
    add_reference :chat_ring_knowledge_versions, :knowledge_base,
                  foreign_key: { to_table: :chat_ring_knowledge_bases, on_delete: :cascade }
    add_reference :chat_ring_knowledge_file_sources, :knowledge_base,
                  foreign_key: { to_table: :chat_ring_knowledge_bases, on_delete: :cascade }
    add_reference :chat_ring_knowledge_documents, :knowledge_material,
                  foreign_key: { to_table: :chat_ring_knowledge_materials, on_delete: :restrict }
    add_reference :chat_ring_knowledge_provider_cleanups, :knowledge_base,
                  foreign_key: { to_table: :chat_ring_knowledge_bases, on_delete: :nullify }
  end

  def backfill_workspace_catalogs
    reset_legacy_columns
    account_ids.each do |account_id|
      workspace_id = insert_workspace(account_id)
      knowledge_base_id = insert_knowledge_base(workspace_id)
      scope_existing_rows(account_id, workspace_id, knowledge_base_id)
      active_id = compatible_active_provider_build(account_id)
      backfill_materials(account_id, knowledge_base_id, active_id)
      normalize_hidden_indexes(account_id, active_id)
      execute <<~SQL.squish
        UPDATE chat_ring_knowledge_bases
        SET active_knowledge_version_id = #{active_id || 'NULL'}, updated_at = CURRENT_TIMESTAMP
        WHERE id = #{knowledge_base_id}
      SQL
      execute <<~SQL.squish
        INSERT INTO chat_ring_knowledge_scopes (workspace_id, name, business_wide, created_at, updated_at)
        VALUES (#{workspace_id}, 'Business-wide', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
  end

  def enforce_workspace_scope
    change_column_null :chat_ring_knowledge_versions, :workspace_id, false
    change_column_null :chat_ring_knowledge_versions, :knowledge_base_id, false
    change_column_null :chat_ring_knowledge_file_sources, :knowledge_base_id, false
    change_column_null :chat_ring_knowledge_documents, :knowledge_material_id, false

    add_foreign_key :chat_ring_knowledge_bases, :chat_ring_knowledge_versions,
                    column: :active_knowledge_version_id, on_delete: :nullify

    remove_check_constraint :chat_ring_knowledge_file_sources, name: 'chatring_file_sources_status_check'
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_file_sources
      SET status = 'deleted', disabled_at = COALESCE(disabled_at, CURRENT_TIMESTAMP), updated_at = CURRENT_TIMESTAMP
      WHERE status = 'disabled'
    SQL
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "status IN ('uploaded', 'parsing', 'ready', 'refreshing', 'refresh_failed', " \
                         "'parse_indeterminate', 'failed', 'deleted')",
                         name: 'chatring_file_sources_status_check'

    remove_check_constraint :chat_ring_knowledge_file_sources, name: 'chatring_file_sources_kind_check'
    add_check_constraint :chat_ring_knowledge_file_sources,
                         "source_kind IN ('pdf', 'docx', 'doc', 'odt', 'rtf', 'xlsx', 'xls', 'html')",
                         name: 'chatring_file_sources_kind_check'

    remove_check_constraint :chat_ring_knowledge_documents,
                            name: 'chatring_knowledge_documents_source_kind_check'
    add_check_constraint :chat_ring_knowledge_documents,
                         "source_kind IN ('website', 'pdf', 'docx', 'doc', 'odt', 'rtf', 'xlsx', 'xls', 'html')",
                         name: 'chatring_knowledge_documents_source_kind_check'

    remove_index :chat_ring_knowledge_file_sources, name: 'index_chatring_file_sources_on_scope_content_and_parser'
    add_index :chat_ring_knowledge_file_sources,
              [:knowledge_base_id, :raw_content_hash, :parser_profile_digest],
              unique: true, name: 'index_chatring_file_sources_on_base_content_and_parser'
    remove_index :chat_ring_knowledge_file_sources, name: 'index_chatring_file_sources_on_scope_and_status'
    add_index :chat_ring_knowledge_file_sources, [:knowledge_base_id, :status],
              name: 'index_chatring_file_sources_on_base_and_status'

    remove_index :chat_ring_knowledge_versions, name: 'index_chatring_knowledge_versions_on_scope_and_created_at'
    add_index :chat_ring_knowledge_versions, [:knowledge_base_id, :created_at],
              name: 'index_chatring_versions_on_base_and_created_at'

    remove_index :chat_ring_knowledge_provider_cleanups, name: 'index_chatring_provider_cleanups_on_scope'
    add_index :chat_ring_knowledge_provider_cleanups, :knowledge_base_id,
              name: 'index_chatring_provider_cleanups_on_base'

    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_evaluation_status_check'
    remove_index :chat_ring_knowledge_versions,
                 name: 'index_chatring_knowledge_versions_on_abandonment_candidates'
    remove_column :chat_ring_knowledge_versions, :evaluation_status
    remove_column :chat_ring_knowledge_versions, :evaluation_report
    remove_column :chat_ring_knowledge_versions, :evaluated_at
    remove_index :chat_ring_knowledge_versions, name: 'index_chat_ring_knowledge_versions_on_processing_lease_token'
    remove_column :chat_ring_knowledge_versions, :processing_lease_expires_at
    remove_column :chat_ring_knowledge_versions, :processing_lease_token

    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_status_check'
    remove_check_constraint :chat_ring_knowledge_versions,
                            name: 'chatring_knowledge_versions_abandonment_fields_check'
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_versions
      SET status = CASE status
                     WHEN 'ingesting' THEN 'building'
                     WHEN 'published' THEN 'active'
                     WHEN 'abandoned' THEN 'discarded'
                     ELSE status
                   END
    SQL
    add_check_constraint :chat_ring_knowledge_versions,
                         "status IN ('building', 'ready', 'active', 'retired', 'failed', 'discarded')",
                         name: 'chatring_knowledge_versions_status_check'
    add_check_constraint :chat_ring_knowledge_versions,
                         "status != 'discarded' OR (abandoned_at IS NOT NULL AND abandon_reason IS NOT NULL)",
                         name: 'chatring_knowledge_indexes_discard_fields_check'

    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_provider_cleanups
      SET status = 'pending'
      WHERE status = 'retrying'
    SQL
    remove_check_constraint :chat_ring_knowledge_provider_cleanups,
                            name: 'chatring_provider_cleanups_lease_status_check'
    remove_check_constraint :chat_ring_knowledge_provider_cleanups,
                            name: 'chatring_provider_cleanups_lease_pair_check'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_expired_leases'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_due_work'
    remove_index :chat_ring_knowledge_provider_cleanups,
                 name: 'index_chatring_provider_cleanups_on_lease_token'
    remove_column :chat_ring_knowledge_provider_cleanups, :manual_retry_count
    remove_column :chat_ring_knowledge_provider_cleanups, :last_enqueued_at
    remove_column :chat_ring_knowledge_provider_cleanups, :next_attempt_at
    remove_column :chat_ring_knowledge_provider_cleanups, :lease_expires_at
    remove_column :chat_ring_knowledge_provider_cleanups, :lease_token
  end

  def remove_per_inbox_publication_boundary
    drop_table :chat_ring_knowledge_publication_events
    drop_table :chat_ring_knowledge_publications

    remove_reference :chat_ring_knowledge_versions, :account, foreign_key: true, index: true
    remove_reference :chat_ring_knowledge_versions, :inbox, foreign_key: true, index: true
    remove_column :chat_ring_knowledge_versions, :root_url
    remove_column :chat_ring_knowledge_versions, :firecrawl_start_started_at
    remove_index :chat_ring_knowledge_versions, name: 'index_chat_ring_knowledge_versions_on_firecrawl_crawl_id'
    remove_column :chat_ring_knowledge_versions, :firecrawl_crawl_id

    remove_reference :chat_ring_knowledge_file_sources, :account, foreign_key: true, index: true
    remove_reference :chat_ring_knowledge_file_sources, :inbox, foreign_key: true, index: true
    remove_column :chat_ring_knowledge_provider_cleanups, :inbox_id
  end

  # The old implementation exposed these records as Knowledge Versions. They
  # are only immutable DocsGPT index builds now; administrators never manage
  # or publish them.
  def rename_hidden_provider_storage
    rename_column :chat_ring_knowledge_bases, :active_knowledge_version_id, :active_knowledge_index_id
    rename_column :chat_ring_knowledge_documents, :knowledge_version_id, :knowledge_index_id
    rename_column :chat_ring_knowledge_provider_cleanups, :knowledge_version_id, :knowledge_index_id
    rename_column :chat_ring_knowledge_versions, :abandoned_at, :discarded_at
    rename_column :chat_ring_knowledge_versions, :abandon_reason, :discard_reason
    rename_column :chat_ring_knowledge_versions, :published_at, :activated_at
    rename_table :chat_ring_knowledge_versions, :chat_ring_knowledge_indexes
  end

  def reset_legacy_columns
    LegacyVersion.reset_column_information
    LegacyDocument.reset_column_information
    LegacyPublication.reset_column_information
  end

  def account_ids
    select_values('SELECT id FROM accounts ORDER BY id').map(&:to_i)
  end

  def insert_workspace(account_id)
    select_value(<<~SQL.squish).to_i
      INSERT INTO chat_ring_workspaces (chatwoot_account_id, status, policy_version, created_at, updated_at)
      VALUES (#{account_id}, 'active', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def insert_knowledge_base(workspace_id)
    select_value(<<~SQL.squish).to_i
      INSERT INTO chat_ring_knowledge_bases (workspace_id, created_at, updated_at)
      VALUES (#{workspace_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def scope_existing_rows(account_id, workspace_id, knowledge_base_id)
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_versions
      SET workspace_id = #{workspace_id}, knowledge_base_id = #{knowledge_base_id}
      WHERE account_id = #{account_id}
    SQL
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_file_sources
      SET knowledge_base_id = #{knowledge_base_id}
      WHERE account_id = #{account_id}
    SQL
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_provider_cleanups
      SET knowledge_base_id = #{knowledge_base_id}
      WHERE knowledge_version_id IN (
        SELECT id FROM chat_ring_knowledge_versions WHERE knowledge_base_id = #{knowledge_base_id}
      )
    SQL
  end

  def compatible_active_provider_build(account_id)
    publications = LegacyPublication.where(account_id: account_id).order(:id).to_a
    return fallback_active_provider_build(account_id) if publications.empty?

    digests = publications.map { |publication| corpus_digest(publication.knowledge_version_id) }.uniq
    if digests.many?
      raise ActiveRecord::IrreversibleMigration,
            "Account #{account_id} has conflicting per-Inbox knowledge; resolve it before Workspace cutover"
    end
    publications.max_by { |publication| [publication.published_at || Time.at(0), publication.id] }.knowledge_version_id
  end

  def normalize_hidden_indexes(account_id, active_id)
    if active_id
      execute <<~SQL.squish
        UPDATE chat_ring_knowledge_versions
        SET status = 'published', published_at = COALESCE(published_at, CURRENT_TIMESTAMP), updated_at = CURRENT_TIMESTAMP
        WHERE id = #{active_id}
      SQL
    end
    execute <<~SQL.squish
      UPDATE chat_ring_knowledge_versions
      SET status = CASE
                     WHEN status IN ('ready', 'published', 'retired') THEN 'retired'
                     ELSE 'failed'
                   END,
          failure_code = CASE
                           WHEN status IN ('ready', 'published', 'retired') THEN failure_code
                           ELSE COALESCE(failure_code, 'workspace_catalog_cutover')
                         END,
          updated_at = CURRENT_TIMESTAMP
      WHERE account_id = #{account_id}
        AND id != #{active_id || 0}
        AND status != 'abandoned'
    SQL
  end

  def fallback_active_provider_build(account_id)
    LegacyVersion.where(account_id: account_id, status: 'published').order(published_at: :desc, id: :desc).pick(:id)
  end

  def corpus_digest(version_id)
    rows = LegacyDocument.where(knowledge_version_id: version_id).order(:source_reference)
                         .pluck(:source_kind, :source_reference, :public_url, :content_hash, :metadata)
    Digest::SHA256.hexdigest(rows.to_json)
  end

  def backfill_materials(account_id, knowledge_base_id, active_version_id)
    version_ids = LegacyVersion.where(account_id: account_id).pluck(:id)
    documents = LegacyDocument.where(knowledge_version_id: version_ids).order(:id).to_a
    active_references = documents.select { |document| document.knowledge_version_id == active_version_id }
                                 .map(&:source_reference).to_set

    documents.group_by(&:source_reference).each_value do |rows|
      document = rows.find { |row| row.knowledge_version_id == active_version_id } || rows.last
      source_columns = material_source_columns(document, knowledge_base_id)
      active_material = active_references.include?(document.source_reference) && !disabled_file_document?(document)
      deleted_at = active_material ? 'NULL' : 'CURRENT_TIMESTAMP'
      material_id = select_value(<<~SQL.squish).to_i
        INSERT INTO chat_ring_knowledge_materials
          (knowledge_base_id, website_source_id, file_source_id, source_kind, source_reference, title, public_url,
           status, markdown, content_hash, authority_class, metadata, extracted_at, deleted_at, created_at, updated_at)
        VALUES
          (#{knowledge_base_id}, #{source_columns.fetch(:website_source_id)}, #{source_columns.fetch(:file_source_id)},
           #{quote(document.source_kind)}, #{quote(document.source_reference)}, #{quote(document.title)},
           #{quote(document.public_url)}, 'available', #{quote(document.markdown)}, #{quote(document.content_hash)},
           #{quote(document.metadata.to_h['authority_class'].presence || 'product_documentation')},
           #{quote(document.metadata.to_json)}::jsonb, #{quote(document.updated_at)}, #{deleted_at},
           CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
      SQL
      execute <<~SQL.squish
        UPDATE chat_ring_knowledge_documents
        SET knowledge_material_id = #{material_id}
        WHERE knowledge_version_id IN (#{version_ids.join(',')})
          AND source_reference = #{quote(document.source_reference)}
      SQL
    end
  end

  def material_source_columns(document, knowledge_base_id)
    return { website_source_id: website_source_id(document, knowledge_base_id), file_source_id: 'NULL' } if document.source_kind == 'website'
    raise ActiveRecord::IrreversibleMigration, "File document #{document.id} has no file source" if document.file_source_id.blank?

    { website_source_id: 'NULL', file_source_id: document.file_source_id }
  end

  def disabled_file_document?(document)
    return false if document.source_kind == 'website' || document.file_source_id.blank?

    select_value(<<~SQL.squish) == 'disabled'
      SELECT status FROM chat_ring_knowledge_file_sources WHERE id = #{document.file_source_id}
    SQL
  end

  def website_source_id(document, knowledge_base_id)
    root_url = website_root(document)
    existing = select_value(<<~SQL.squish)
      SELECT id FROM chat_ring_knowledge_website_sources
      WHERE knowledge_base_id = #{knowledge_base_id} AND root_url = #{quote(root_url)}
    SQL
    return existing.to_i if existing

    select_value(<<~SQL.squish).to_i
      INSERT INTO chat_ring_knowledge_website_sources
        (knowledge_base_id, root_url, status, last_processed_at, created_at, updated_at)
      VALUES
        (#{knowledge_base_id}, #{quote(root_url)}, 'available', #{quote(document.updated_at)},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def website_root(document)
    legacy_root = LegacyVersion.where(id: document.knowledge_version_id).pick(:root_url)
    return legacy_root if legacy_root.present?

    url = URI.parse(document.public_url.presence || document.source_reference)
    port = url.default_port == url.port ? '' : ":#{url.port}"
    "#{url.scheme}://#{url.host}#{port}/"
  rescue URI::InvalidURIError
    raise ActiveRecord::IrreversibleMigration, "Website document #{document.id} has an invalid public URL"
  end

  def select_value(sql)
    connection.select_value(sql)
  end

  def select_values(sql)
    connection.select_values(sql)
  end

  def select_rows(sql)
    connection.select_all(sql).to_a
  end

  def quote(value)
    connection.quote(value)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
end
