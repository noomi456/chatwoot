class ChatRing::Tools::InboxCapabilityProfile
  Capability = Data.define(:key, :version, :available, :renderer, :fallback, :reason) do
    def as_json(*)
      to_h
    end
  end

  def initialize(inbox:, policy_version:)
    unless policy_version.inbox_tool_policy.chatwoot_inbox_id == inbox.id
      raise ArgumentError, 'Inbox Tool policy version does not belong to this Inbox'
    end

    @inbox = inbox
    @policy_version = policy_version
  end

  def capabilities
    policy_version.enabled_tools.map do |item|
      capability_for(ChatRing::Tools::Registry.fetch(item.fetch('key'), item.fetch('version')))
    end
  end

  def fetch(key, version)
    capabilities.find { |item| item.key == key.to_s && item.version == version.to_i } ||
      Capability.new(key: key.to_s, version: version.to_i, available: false, renderer: nil, fallback: nil,
                     reason: 'tool_not_enabled')
  end

  private

  attr_reader :inbox, :policy_version

  def capability_for(definition)
    return request_appointment_capability(definition) if definition.key == 'request_appointment'

    Capability.new(key: definition.key, version: definition.version, available: false, renderer: nil, fallback: nil,
                   reason: 'renderer_not_implemented')
  end

  def request_appointment_capability(definition)
    return uncertified_channel_capability(definition) unless inbox.web_widget?

    configuration = policy_version.configuration_for(definition.key)
    fallback = configuration.fetch('fallback_mode')
    renderer = configuration.fetch('website_presentation', fallback)
    Capability.new(
      key: definition.key,
      version: definition.version,
      available: true,
      renderer: renderer,
      fallback: fallback,
      reason: nil
    )
  end

  def uncertified_channel_capability(definition)
    Capability.new(
      key: definition.key,
      version: definition.version,
      available: false,
      renderer: nil,
      fallback: nil,
      reason: 'channel_not_certified'
    )
  end
end
