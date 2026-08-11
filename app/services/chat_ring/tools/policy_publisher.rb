class ChatRing::Tools::PolicyPublisher
  class InvalidRevision < StandardError; end

  # rubocop:disable Metrics/ParameterLists
  def initialize(workspace:, inbox:, actor:, expected_lock_version:, enabled_tools:, tool_configurations:, renderer_policy: {})
    @workspace = workspace
    @inbox = inbox
    @actor = actor
    @expected_lock_version = Integer(expected_lock_version)
    @enabled_tools = normalize_enabled_tools(enabled_tools)
    @tool_configurations = tool_configurations.to_h.deep_stringify_keys
    @renderer_policy = renderer_policy.to_h.deep_stringify_keys
  end
  # rubocop:enable Metrics/ParameterLists

  def call
    validate_native_scope!
    Account.transaction do
      Account.lock.find(workspace.chatwoot_account_id)
      Inbox.lock.find(inbox.id)
      policy = find_or_create_policy!
      raise InvalidRevision, 'Inbox Tool policy changed; reload before publishing' unless policy.lock_version == expected_lock_version

      version = create_version!(policy)
      policy.update!(current_version: version, status: :active)
      version
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  attr_reader :workspace, :inbox, :actor, :expected_lock_version, :enabled_tools, :tool_configurations, :renderer_policy

  def find_or_create_policy!
    ChatRing::InboxToolPolicy.find_or_create_by!(workspace: workspace, chatwoot_inbox_id: inbox.id)
  end

  def create_version!(policy)
    policy.versions.create!(
      version: policy.versions.maximum(:version).to_i + 1,
      enabled_tools: enabled_tools,
      tool_configurations: tool_configurations,
      renderer_policy: renderer_policy,
      created_by: actor,
      published_at: Time.current
    )
  end

  def validate_native_scope!
    return if inbox.account_id == workspace.chatwoot_account_id

    raise ActiveRecord::RecordNotFound, 'Inbox does not belong to this Workspace'
  end

  def normalize_enabled_tools(items)
    normalized = Array(items).map do |item|
      attributes = item.to_h.deep_stringify_keys.slice('key', 'version')
      attributes['version'] = Integer(attributes.fetch('version'))
      attributes
    end
    normalized.sort_by { |item| [item.fetch('key'), item.fetch('version')] }
  end
end
