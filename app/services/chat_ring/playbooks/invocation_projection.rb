class ChatRing::Playbooks::InvocationProjection
  def initialize(turn)
    @turn = turn
  end

  def trusted_context
    return {} unless execution

    {
      'inbox_playbook_execution_id' => execution.id,
      'inbox_playbook_version_id' => execution.inbox_playbook_version_id,
      'playbook_step_id' => turn.playbook_step_id,
      'playbook_execution_lock_version' => turn.playbook_execution_lock_version
    }
  end

  def model_context
    return unless execution

    {
      'goal' => version.purpose,
      'status' => execution.status,
      'current_step' => projected_step,
      'collected_field_keys' => execution.collected_fields.keys.sort,
      'pending_question' => pending_question,
      'safety_rules' => version.definition['safety_rules']
    }
  end

  def tool_allowlist
    return unless execution

    version_tools.select do |version_tool|
      step_tools.any? { |step_tool| tool_identity(step_tool) == tool_identity(version_tool) }
    end
  end

  def audit_metadata
    trusted_context
  end

  private

  attr_reader :turn

  def execution
    @execution ||= turn.inbox_playbook_execution
  end

  def version
    @version ||= execution.inbox_playbook_version
  end

  def step
    @step ||= Array(version.definition['steps']).find { |item| item['id'] == turn.playbook_step_id } || {}
  end

  def pending_question
    step['prompt'] if %w[ask_text ask_choice].include?(step['kind'])
  end

  def projected_step
    result = step.slice('kind', 'prompt')
    field = Array(version.definition['collected_fields']).find { |item| item['key'] == step['field_key'] }
    result['field'] = field.slice('type', 'required') if field
    result['choices'] = Array(step['choices']).map { |choice| choice.slice('label', 'value') } if step['kind'] == 'ask_choice'
    result
  end

  def version_tools
    Array(version.definition['tool_allowlist'])
  end

  def step_tools
    Array(step['tool_allowlist'])
  end

  def tool_identity(tool)
    tool.values_at('key', 'version')
  end
end
