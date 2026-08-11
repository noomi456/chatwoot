class ChatRing::Tools::AvailabilityResolver
  def initialize(inbox:, assistant_version:, allowed_tools: nil)
    @inbox = inbox
    @assistant_version = assistant_version
    @allowed_tools = allowed_tools
  end

  def call
    return [] unless policy_version

    grants = ChatRing::Tools::GrantSet.new(assistant_version.tool_grants)
    profile = ChatRing::Tools::InboxCapabilityProfile.new(inbox: inbox, policy_version: policy_version)
    grants.entries.filter_map do |grant|
      next unless tool_allowed?(grant)

      available_definition(profile, grant)
    end
  rescue ChatRing::Tools::GrantSet::Invalid, KeyError
    []
  end

  private

  attr_reader :inbox, :assistant_version, :allowed_tools

  def tool_allowed?(grant)
    return true if allowed_tools.nil?

    allowed_tools.any? do |item|
      attributes = item.to_h.deep_stringify_keys
      attributes['key'] == grant['key'] && attributes['version'].to_i == grant['version']
    end
  end

  def policy_version
    @policy_version ||= ChatRing::InboxToolPolicy.active.includes(:current_version).find_by(
      workspace_id: assistant_version.assistant.workspace_id,
      chatwoot_inbox_id: inbox.id
    )&.current_version
  end

  def available_definition(profile, grant)
    capability = profile.fetch(grant.fetch('key'), grant.fetch('version'))
    return unless capability.available

    definition = ChatRing::Tools::Registry.fetch(capability.key, capability.version)
    {
      'key' => definition.key,
      'version' => definition.version,
      'description' => definition.description,
      'input_schema' => definition.input_schema
    }
  end
end
