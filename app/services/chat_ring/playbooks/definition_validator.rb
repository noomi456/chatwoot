# A single compiler keeps normalization and validation deterministic before an
# immutable version is written. Runtime execution never consumes draft input.
class ChatRing::Playbooks::DefinitionValidator # rubocop:disable Metrics/ClassLength
  Result = Data.define(:errors, :warnings, :definition, :capability_snapshot) do
    def valid?
      errors.empty?
    end

    def as_json(*)
      { valid: valid?, errors: errors, warnings: warnings }
    end
  end

  TOP_LEVEL_KEYS = %w[trigger_phrases entry_step_id steps collected_fields tool_allowlist safety_rules].freeze
  STEP_KINDS = %w[ask_text ask_choice inform tool terminal transition].freeze
  FIELD_TYPES = %w[string email phone number boolean choice].freeze
  TERMINAL_OUTCOMES = %w[complete stop handoff].freeze
  COMMON_STEP_KEYS = %w[id kind tool_allowlist].freeze
  STEP_KEYS = {
    'ask_text' => %w[prompt field_key next_step_id],
    'ask_choice' => %w[prompt field_key choices],
    'inform' => %w[message next_step_id],
    'tool' => %w[tool next_step_id],
    'terminal' => %w[outcome],
    'transition' => %w[target_playbook_version_id carry_fields]
  }.freeze
  MAX_TRIGGERS = 20
  MAX_STEPS = 25
  MAX_FIELDS = 20
  MAX_TOOLS = 5
  MAX_DEPTH = 25
  MAX_TRANSITION_DEPTH = 5
  SIMPLE_PHRASES = %w[hello hi hey thanks thank-you ok okay yes no].freeze
  CONTACT_DISPLAY_TYPES = {
    'string' => ['text'],
    'email' => ['text'],
    'phone' => ['text'],
    'number' => %w[number currency percent],
    'boolean' => ['checkbox'],
    'choice' => ['list']
  }.freeze

  def initialize(playbook:, definition:)
    @playbook = playbook
    @source = definition
    @errors = []
    @warnings = []
    @definition = definition.is_a?(Hash) ? definition.deep_stringify_keys : {}
  end

  def call
    validate_root
    normalize_triggers
    normalize_tools
    validate_fields
    validate_steps
    validate_safety_rules
    validate_trigger_conflicts
    validate_transition_graph

    Result.new(
      errors: errors.freeze,
      warnings: warnings.freeze,
      definition: definition.deep_dup.freeze,
      capability_snapshot: capability_snapshot.deep_dup.freeze
    )
  end

  private

  attr_reader :playbook, :source, :errors, :warnings, :definition

  def validate_root
    unless source.is_a?(Hash)
      add_error('invalid_definition', '$', 'Definition must be an object')
      return
    end

    unknown_keys = definition.keys - TOP_LEVEL_KEYS
    add_error('unknown_definition_keys', '$', "Unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
    TOP_LEVEL_KEYS.each do |key|
      add_error('missing_definition_key', key, 'is required') unless definition.key?(key)
    end
  end

  def normalize_triggers
    values = definition['trigger_phrases']
    unless values.is_a?(Array)
      add_error('invalid_trigger_phrases', 'trigger_phrases', 'must be an array')
      definition['trigger_phrases'] = []
      return
    end

    normalized = values.map { |value| ChatRing::Playbooks::PhraseNormalizer.call(value) }
    add_error('trigger_count', 'trigger_phrases', "must contain 1 to #{MAX_TRIGGERS} phrases") unless normalized.length.between?(1, MAX_TRIGGERS)
    normalized.each_with_index { |phrase, index| validate_trigger(phrase, index) }
    add_error('duplicate_trigger', 'trigger_phrases', 'contains duplicate normalized phrases') unless normalized.uniq.length == normalized.length
    definition['trigger_phrases'] = normalized.uniq
  end

  def validate_trigger(phrase, index)
    path = "trigger_phrases[#{index}]"
    add_error('trigger_too_short', path, 'must contain at least 3 characters') if phrase.length < 3
    if phrase.length > ChatRing::Playbooks::PhraseNormalizer::MAX_LENGTH
      add_error(
        'trigger_too_long',
        path,
        "must be at most #{ChatRing::Playbooks::PhraseNormalizer::MAX_LENGTH} characters"
      )
    end
    add_error('trigger_too_vague', path, 'cannot be a greeting, acknowledgement, or bare yes/no phrase') if SIMPLE_PHRASES.include?(phrase)
  end

  def normalize_tools
    values = definition['tool_allowlist']
    unless values.is_a?(Array)
      add_error('invalid_tool_allowlist', 'tool_allowlist', 'must be an array')
      definition['tool_allowlist'] = []
      return
    end

    normalized = values.each_with_index.filter_map do |value, index|
      normalize_tool(value, "tool_allowlist[#{index}]")
    end
    identifiers = normalized.map { |item| "#{item['key']}@#{item['version']}" }
    add_error('tool_count', 'tool_allowlist', "must contain at most #{MAX_TOOLS} Tools") if normalized.length > MAX_TOOLS
    add_error('duplicate_tool', 'tool_allowlist', 'contains duplicate Tool versions') unless identifiers.uniq.length == identifiers.length
    definition['tool_allowlist'] = normalized.uniq
    validate_tool_policy(normalized)
  end

  def normalize_tool(value, path)
    unless value.is_a?(Hash)
      add_error('invalid_tool', path, 'must contain a key and version')
      return
    end

    item = value.deep_stringify_keys
    unknown_keys = item.keys - %w[key version]
    add_error('unknown_tool_keys', path, "contains unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
    item = item.slice('key', 'version')
    version = Integer(item.fetch('version'))
    key = item.fetch('key').to_s
    ChatRing::Tools::Registry.fetch(key, version)
    { 'key' => key, 'version' => version }
  rescue KeyError, ArgumentError, TypeError
    add_error('unknown_tool', path, 'must identify a registered Tool version')
    nil
  end

  def validate_tool_policy(tools)
    return if tools.empty?

    unless current_tool_policy&.active? && current_tool_policy.current_version
      add_error('tool_policy_missing', 'tool_allowlist', 'Inbox does not have an active Tool policy')
      return
    end

    profile = ChatRing::Tools::InboxCapabilityProfile.new(inbox: playbook.inbox, policy_version: current_tool_policy.current_version)
    tools.each do |item|
      capability = profile.fetch(item.fetch('key'), item.fetch('version'))
      next if capability.available

      add_error('tool_unavailable', 'tool_allowlist', "#{item['key']}@#{item['version']} is unavailable: #{capability.reason}")
    end
  end

  def validate_fields
    fields = definition['collected_fields']
    unless fields.is_a?(Array)
      add_error('invalid_collected_fields', 'collected_fields', 'must be an array')
      definition['collected_fields'] = []
      return
    end

    add_error('field_count', 'collected_fields', "must contain at most #{MAX_FIELDS} fields") if fields.length > MAX_FIELDS
    normalized = fields.each_with_index.filter_map { |field, index| normalize_field(field, index) }
    keys = normalized.pluck('key')
    add_error('duplicate_field', 'collected_fields', 'contains duplicate field keys') unless keys.uniq.length == keys.length
    definition['collected_fields'] = normalized
  end

  def normalize_field(value, index)
    path = "collected_fields[#{index}]"
    unless value.is_a?(Hash)
      add_error('invalid_field', path, 'must be an object')
      return
    end

    field = value.deep_stringify_keys
    unknown_keys = field.keys - %w[key type required native_contact_attribute_key]
    add_error('unknown_field_keys', path, "contains unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
    field = field.slice('key', 'type', 'required', 'native_contact_attribute_key')
    key = field['key'].to_s
    type = field['type'].to_s
    unless key.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
      add_error('invalid_field_key', "#{path}.key", 'must use lowercase letters, numbers, and underscores')
    end
    add_error('invalid_field_type', "#{path}.type", "must be one of #{FIELD_TYPES.join(', ')}") unless FIELD_TYPES.include?(type)
    add_error('invalid_required_flag', "#{path}.required", 'must be true or false') unless [true, false].include?(field['required'])
    validate_native_contact_attribute(field, type, path)
    field
  end

  def validate_native_contact_attribute(field, type, path)
    key = field['native_contact_attribute_key'].to_s.presence
    field['native_contact_attribute_key'] = key
    return unless key

    definition_record = CustomAttributeDefinition.find_by(
      account_id: playbook.workspace.chatwoot_account_id,
      attribute_model: 'contact_attribute',
      attribute_key: key
    )
    unless definition_record
      add_error('unknown_contact_attribute', "#{path}.native_contact_attribute_key", 'must identify a native Contact custom attribute')
      return
    end

    return if compatible_contact_attribute_type?(type, definition_record.attribute_display_type)

    add_error('contact_attribute_type_mismatch', "#{path}.native_contact_attribute_key", 'does not match the native Contact attribute type')
  end

  def compatible_contact_attribute_type?(field_type, display_type)
    CONTACT_DISPLAY_TYPES.fetch(field_type, []).include?(display_type)
  end

  def validate_steps
    steps = definition['steps']
    unless steps.is_a?(Array)
      add_error('invalid_steps', 'steps', 'must be an array')
      definition['steps'] = []
      return
    end

    add_error('step_count', 'steps', "must contain 1 to #{MAX_STEPS} steps") unless steps.length.between?(1, MAX_STEPS)
    normalized = steps.each_with_index.filter_map { |step, index| normalize_step(step, index) }
    definition['steps'] = normalized
    validate_step_graph(normalized)
  end

  def normalize_step(value, index)
    path = "steps[#{index}]"
    unless value.is_a?(Hash)
      add_error('invalid_step', path, 'must be an object')
      return
    end

    step = value.deep_stringify_keys
    id = step['id'].to_s
    kind = step['kind'].to_s
    add_error('invalid_step_id', "#{path}.id", 'must use lowercase letters, numbers, and underscores') unless id.match?(/\A[a-z][a-z0-9_]{0,63}\z/)
    add_error('invalid_step_kind', "#{path}.kind", "must be one of #{STEP_KINDS.join(', ')}") unless STEP_KINDS.include?(kind)
    validate_step_keys(step, kind, path)
    normalize_step_tools(step, path)
    validate_step_contract(step, path) if STEP_KINDS.include?(kind)
    step
  end

  def normalize_step_tools(step, path)
    tools = step.fetch('tool_allowlist', [])
    unless tools.is_a?(Array)
      add_error('invalid_step_tool_allowlist', "#{path}.tool_allowlist", 'must be an array')
      step['tool_allowlist'] = []
      return
    end

    step['tool_allowlist'] = tools.each_with_index.filter_map do |tool, index|
      normalize_tool(tool, "#{path}.tool_allowlist[#{index}]")
    end
    allowed = definition.fetch('tool_allowlist', []).map { |item| [item['key'], item['version']] }
    step['tool_allowlist'].each do |tool|
      next if allowed.include?([tool['key'], tool['version']])

      add_error('step_tool_not_allowed', "#{path}.tool_allowlist", "#{tool['key']}@#{tool['version']} is not in the Playbook allowlist")
    end
  end

  def validate_step_keys(step, kind, path)
    allowed = COMMON_STEP_KEYS + STEP_KEYS.fetch(kind, [])
    unknown_keys = step.keys - allowed
    add_error('unknown_step_keys', path, "contains unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
  end

  def validate_step_contract(step, path) # rubocop:disable Metrics/CyclomaticComplexity
    case step['kind']
    when 'ask_text'
      validate_prompt_and_field(step, path)
      require_next_step(step, path)
    when 'ask_choice'
      validate_prompt_and_field(step, path)
      normalize_choices(step, path)
    when 'inform'
      require_text(step, 'message', path)
      require_next_step(step, path)
    when 'tool'
      normalize_tool_step(step, path)
    when 'terminal'
      unless TERMINAL_OUTCOMES.include?(step['outcome'])
        add_error('invalid_terminal_outcome', "#{path}.outcome", "must be one of #{TERMINAL_OUTCOMES.join(', ')}")
      end
    when 'transition'
      normalize_transition_step(step, path)
    end
  end

  def validate_prompt_and_field(step, path)
    require_text(step, 'prompt', path)
    field_key = step['field_key'].to_s
    known_fields = definition.fetch('collected_fields', []).pluck('key')
    add_error('unknown_step_field', "#{path}.field_key", 'must reference a collected field') unless known_fields.include?(field_key)
  end

  def require_text(step, key, path)
    value = step[key]
    add_error('missing_step_text', "#{path}.#{key}", 'is required') unless value.is_a?(String) && value.strip.present?
    add_error('step_text_too_long', "#{path}.#{key}", 'must be at most 1000 characters') if value.to_s.length > 1000
  end

  def require_next_step(step, path)
    add_error('missing_next_step', "#{path}.next_step_id", 'is required') if step['next_step_id'].to_s.blank?
  end

  def normalize_choices(step, path)
    choices = step['choices']
    unless choices.is_a?(Array) && choices.length.between?(2, 12)
      add_error('invalid_choices', "#{path}.choices", 'must contain 2 to 12 choices')
      return
    end

    normalized = choices.each_with_index.filter_map do |choice, index|
      normalize_choice(choice, "#{path}.choices[#{index}]")
    end
    values = normalized.pluck('value')
    add_error('duplicate_choice', "#{path}.choices", 'contains duplicate values') unless values.uniq.length == values.length
    step['choices'] = normalized
  end

  def normalize_choice(value, path)
    unless value.is_a?(Hash)
      add_error('invalid_choice', path, 'must be an object')
      return
    end

    choice = value.deep_stringify_keys
    unknown_keys = choice.keys - %w[label value next_step_id]
    add_error('unknown_choice_keys', path, "contains unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
    choice = choice.slice('label', 'value', 'next_step_id')
    %w[label value next_step_id].each do |key|
      add_error('missing_choice_value', "#{path}.#{key}", 'is required') if choice[key].to_s.blank?
    end
    choice
  end

  def normalize_tool_step(step, path)
    tool = normalize_tool(step['tool'], "#{path}.tool")
    step['tool'] = tool || {}
    return unless tool

    allowed = step['tool_allowlist'].map { |item| [item['key'], item['version']] }
    return if allowed.include?([tool['key'], tool['version']])

    add_error('tool_step_not_allowed', "#{path}.tool", 'must be included in the step Tool allowlist')
  end

  def normalize_transition_step(step, path)
    target_version_id = Integer(step['target_playbook_version_id'])
    step['target_playbook_version_id'] = target_version_id
    step['carry_fields'] = Array(step['carry_fields']).map(&:to_s).uniq
    unknown_fields = step['carry_fields'] - definition.fetch('collected_fields', []).pluck('key')
    add_error('unknown_transition_field', "#{path}.carry_fields", "contains unknown fields: #{unknown_fields.join(', ')}") if unknown_fields.present?
    validate_transition_target(target_version_id, path)
  rescue ArgumentError, TypeError
    add_invalid_transition_target_error(path)
  end

  def validate_transition_target(target_version_id, path)
    target = ChatRing::InboxPlaybookVersion.joins(:inbox_playbook).find_by(
      id: target_version_id,
      chat_ring_inbox_playbooks: {
        workspace_id: playbook.workspace_id,
        chatwoot_inbox_id: playbook.chatwoot_inbox_id,
        status: ChatRing::InboxPlaybook.statuses.fetch('active')
      }
    )
    add_invalid_transition_target_error(path) if target.blank? || target.inbox_playbook.current_version_id != target.id
  end

  def add_invalid_transition_target_error(path)
    add_error(
      'invalid_transition_target',
      "#{path}.target_playbook_version_id",
      'must identify the current published version of an active Playbook in the same Inbox'
    )
  end

  def validate_step_graph(steps) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    ids = steps.pluck('id')
    add_error('duplicate_step', 'steps', 'contains duplicate step IDs') unless ids.uniq.length == ids.length
    entry = definition['entry_step_id'].to_s
    add_error('invalid_entry_step', 'entry_step_id', 'must reference a step') unless ids.include?(entry)
    targets = steps.to_h { |step| [step['id'], outgoing_step_ids(step)] }
    targets.each do |id, next_ids|
      missing = next_ids - ids
      add_error('missing_branch_target', "steps.#{id}", "references missing steps: #{missing.join(', ')}") if missing.present?
    end
    return unless ids.include?(entry)

    reachable, cycle, depth = traverse_step_graph(entry, targets)
    add_error('step_cycle', 'steps', 'must not contain a cycle') if cycle
    add_error('step_depth', 'steps', "must not exceed #{MAX_DEPTH} transitions") if depth > MAX_DEPTH
    unreachable = ids - reachable
    add_error('unreachable_step', 'steps', "contains unreachable steps: #{unreachable.join(', ')}") if unreachable.present?
  end

  def outgoing_step_ids(step)
    case step['kind']
    when 'ask_text', 'inform', 'tool'
      [step['next_step_id'].to_s].reject(&:blank?)
    when 'ask_choice'
      Array(step['choices']).filter_map { |choice| choice['next_step_id'].to_s.presence }
    else
      []
    end
  end

  def traverse_step_graph(entry, targets)
    reachable = []
    cycle = false
    max_depth = 0
    visit = lambda do |id, path|
      if path.include?(id)
        cycle = true
        return
      end
      return if reachable.include?(id)

      reachable << id
      max_depth = [max_depth, path.length].max
      Array(targets[id]).each { |target| visit.call(target, path + [id]) }
    end
    visit.call(entry, [])
    [reachable, cycle, max_depth]
  end

  def validate_safety_rules
    rules = definition['safety_rules']
    unless rules.is_a?(Hash)
      add_error('invalid_safety_rules', 'safety_rules', 'must be an object')
      definition['safety_rules'] = {}
      return
    end

    rules = rules.deep_stringify_keys
    expected = {
      'on_human_request' => 'native_availability',
      'on_side_question' => 'answer_then_resume'
    }
    unless rules == expected
      add_error(
        'invalid_safety_rules',
        'safety_rules',
        'must preserve native human availability and answer-then-resume behavior'
      )
    end
    definition['safety_rules'] = rules
  end

  def validate_trigger_conflicts # rubocop:disable Metrics/AbcSize
    return if definition.fetch('trigger_phrases', []).empty?

    conflicts = playbook.workspace.inbox_playbooks.active
                        .where(chatwoot_inbox_id: playbook.chatwoot_inbox_id)
                        .where.not(id: playbook.id)
                        .includes(:current_version)
                        .filter_map do |other|
      overlap = other.current_version.normalized_trigger_phrases & definition['trigger_phrases']
      [other, overlap] if overlap.present?
    end
    conflicts.each do |other, overlap|
      add_error('trigger_conflict', 'trigger_phrases', "conflicts with #{other.name}: #{overlap.join(', ')}")
    end
  end

  def validate_transition_graph
    targets = transition_targets(definition)
    return if targets.empty?

    cycle, depth = transition_graph_result(targets, [], 0)
    add_error('playbook_transition_cycle', 'steps', 'must not create a direct or indirect Playbook cycle') if cycle
    add_error('playbook_transition_depth', 'steps', "must not exceed #{MAX_TRANSITION_DEPTH} Playbook transitions") if depth > MAX_TRANSITION_DEPTH
  end

  def transition_targets(value)
    Array(value['steps']).filter_map do |step|
      next unless step['kind'] == 'transition'

      Integer(step['target_playbook_version_id'])
    rescue ArgumentError, TypeError
      nil
    end
  end

  def transition_graph_result(version_ids, path, depth)
    cycle = false
    max_depth = depth
    version_ids.each do |version_id|
      if path.include?(version_id)
        cycle = true
        next
      end

      version = ChatRing::InboxPlaybookVersion.includes(:inbox_playbook).find_by(id: version_id)
      next unless version

      cycle = true if version.inbox_playbook_id == playbook.id
      nested_cycle, nested_depth = transition_graph_result(
        transition_targets(version.definition),
        path + [version_id],
        depth + 1
      )
      cycle ||= nested_cycle
      max_depth = [max_depth, nested_depth].max
    end
    [cycle, max_depth]
  end

  def current_tool_policy
    @current_tool_policy ||= ChatRing::InboxToolPolicy.includes(:current_version).find_by(
      workspace: playbook.workspace,
      chatwoot_inbox_id: playbook.chatwoot_inbox_id
    )
  end

  def capability_snapshot
    version = current_tool_policy&.current_version
    capabilities = if version
                     ChatRing::Tools::InboxCapabilityProfile.new(inbox: playbook.inbox, policy_version: version).capabilities.map(&:as_json)
                   else
                     []
                   end
    {
      'chatwoot_inbox_id' => playbook.chatwoot_inbox_id,
      'channel_type' => playbook.inbox.channel_type,
      'tool_policy_version_id' => version&.id,
      'tools' => capabilities
    }
  end

  def add_error(code, path, message)
    errors << { code: code, path: path, message: message }
  end
end
