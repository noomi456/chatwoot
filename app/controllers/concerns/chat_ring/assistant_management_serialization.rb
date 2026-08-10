module ChatRing::AssistantManagementSerialization
  private

  def serialize_assistant(assistant, include_draft: false)
    result = {
      id: assistant.id,
      name: assistant.name,
      state: assistant_display_state(assistant),
      current_version: serialize_assistant_version(assistant.current_version),
      bindings: assistant.inbox_bindings.where(status: %i[active draining]).order(:chatwoot_inbox_id).map do |binding|
        serialize_binding(binding)
      end,
      configuration_issues: assistant_configuration_issues(assistant),
      created_at: assistant.created_at,
      updated_at: assistant.updated_at
    }
    result[:draft] = serialize_assistant_draft(assistant.configuration_draft) if include_draft
    result
  end

  def serialize_assistant_draft(draft)
    return if draft.blank?

    {
      knowledge_scope_id: draft.knowledge_scope_id,
      identity: draft.identity,
      goals: draft.goals,
      instructions: draft.instructions,
      response_guidelines: draft.response_guidelines,
      guardrails: draft.guardrails,
      handoff_policy: draft.handoff_policy,
      llm_provider: draft.llm_provider,
      llm_model: draft.llm_model,
      lock_version: draft.lock_version,
      updated_at: draft.updated_at
    }
  end

  def serialize_assistant_version(version)
    return if version.blank?

    {
      id: version.id,
      version: version.version,
      knowledge_scope_id: version.knowledge_scope_id,
      llm_provider: version.llm_provider,
      llm_model: version.llm_model,
      published_at: version.published_at
    }
  end

  def serialize_binding(binding)
    {
      id: binding.id,
      inbox_id: binding.chatwoot_inbox_id,
      assistant_id: binding.assistant_id,
      status: binding.status,
      binding_version: binding.binding_version,
      created_at: binding.created_at,
      updated_at: binding.updated_at
    }
  end

  def assistant_display_state(assistant)
    return 'archived' if assistant.archived?
    return 'draft' if assistant.current_version.blank?
    return 'configuration_unhealthy' if assistant_configuration_issues(assistant).any?
    return 'active' if assistant.inbox_bindings.active.exists?

    'published_unbound'
  end

  def assistant_configuration_issues(assistant)
    return [] if assistant.current_version.blank? || assistant.archived?

    connection = assistant.agent_bot_connection
    return ['managed_agent_bot_missing'] if connection.blank?
    return ['managed_agent_bot_unhealthy'] unless connection.active? && connection.valid?

    []
  end
end
