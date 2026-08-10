class CreateChatRingAssistantDrafts < ActiveRecord::Migration[7.1]
  BACKFILL_SQL = <<~SQL.squish.freeze
    INSERT INTO chat_ring_assistant_drafts (
      assistant_id,
      knowledge_scope_id,
      identity,
      goals,
      instructions,
      response_guidelines,
      guardrails,
      audience_policy,
      availability_policy,
      handoff_policy,
      tool_grants,
      conversation_policy,
      llm_provider,
      llm_model,
      published_version_id,
      lock_version,
      created_at,
      updated_at
    )
    SELECT
      assistants.id,
      COALESCE(versions.knowledge_scope_id, scopes.id),
      COALESCE(versions.identity, '{}'::jsonb),
      COALESCE(versions.goals, '[]'::jsonb),
      COALESCE(versions.instructions, ''),
      COALESCE(versions.response_guidelines, '[]'::jsonb),
      COALESCE(versions.guardrails, '[]'::jsonb),
      COALESCE(versions.audience_policy, '{}'::jsonb),
      COALESCE(versions.availability_policy, '{}'::jsonb),
      COALESCE(versions.handoff_policy, '{}'::jsonb),
      COALESCE(versions.tool_grants, '[]'::jsonb),
      COALESCE(versions.conversation_policy, '{}'::jsonb),
      COALESCE(versions.llm_provider, 'openai'),
      COALESCE(versions.llm_model, 'gpt-5.4'),
      versions.id,
      0,
      CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP
    FROM chat_ring_assistants AS assistants
    LEFT JOIN chat_ring_assistant_versions AS versions
      ON versions.id = assistants.current_version_id
    INNER JOIN chat_ring_knowledge_scopes AS scopes
      ON scopes.workspace_id = assistants.workspace_id
      AND scopes.business_wide = TRUE
  SQL

  def up
    create_drafts_table
    execute BACKFILL_SQL
    verify_complete_backfill!
  end

  def down
    drop_table :chat_ring_assistant_drafts
  end

  private

  def create_drafts_table
    create_table :chat_ring_assistant_drafts do |t|
      t.references :assistant,
                   null: false,
                   index: { unique: true },
                   foreign_key: { to_table: :chat_ring_assistants, on_delete: :cascade }
      t.references :knowledge_scope,
                   null: false,
                   foreign_key: { to_table: :chat_ring_knowledge_scopes, on_delete: :restrict }
      add_configuration_columns(t)
      add_publication_columns(t)
      t.timestamps
    end
  end

  def add_configuration_columns(table)
    table.jsonb :identity, null: false, default: {}
    table.jsonb :goals, null: false, default: []
    table.text :instructions, null: false, default: ''
    table.jsonb :response_guidelines, null: false, default: []
    table.jsonb :guardrails, null: false, default: []
    table.jsonb :audience_policy, null: false, default: {}
    table.jsonb :availability_policy, null: false, default: {}
    table.jsonb :handoff_policy, null: false, default: {}
    table.jsonb :tool_grants, null: false, default: []
    table.jsonb :conversation_policy, null: false, default: {}
    table.string :llm_provider, null: false, default: 'openai'
    table.string :llm_model, null: false, default: 'gpt-5.4'
  end

  def add_publication_columns(table)
    table.references :published_version,
                     foreign_key: { to_table: :chat_ring_assistant_versions, on_delete: :nullify }
    table.integer :lock_version, null: false, default: 0
  end

  def verify_complete_backfill!
    assistant_count = select_value('SELECT COUNT(*) FROM chat_ring_assistants').to_i
    draft_count = select_value('SELECT COUNT(*) FROM chat_ring_assistant_drafts').to_i
    return if assistant_count == draft_count

    raise ActiveRecord::MigrationError, "Assistant draft backfill mismatch: expected #{assistant_count}, inserted #{draft_count}"
  end
end
