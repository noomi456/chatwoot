class ChatRing::InboxToolPolicyVersion < ApplicationRecord
  self.table_name = 'chat_ring_inbox_tool_policy_versions'

  PROVIDERS = %w[calendly calcom custom_link].freeze
  FALLBACK_MODES = ['approved_link'].freeze
  APPOINTMENT_CONFIGURATION_KEYS = %w[provider url fallback_mode link_label].freeze

  belongs_to :inbox_tool_policy,
             class_name: 'ChatRing::InboxToolPolicy',
             inverse_of: :versions
  belongs_to :created_by, class_name: 'User', inverse_of: false, optional: true
  has_many :tool_executions,
           class_name: 'ChatRing::ToolExecution',
           inverse_of: :inbox_tool_policy_version,
           dependent: :restrict_with_exception
  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :inbox_tool_policy_id }
  validates :published_at, presence: true
  validate :configuration_shapes
  validate :enabled_tool_definitions_exist
  validate :configuration_keys_match_enabled_tools
  validate :tool_configurations_are_valid
  validate :published_snapshot_is_immutable, on: :update

  def enabled?(key, version = nil)
    return false unless enabled_tools.is_a?(Array)

    enabled_tools.any? do |item|
      item['key'] == key.to_s && (version.nil? || item['version'].to_i == version.to_i)
    end
  end

  def configuration_for(key)
    return {} unless tool_configurations.is_a?(Hash)

    tool_configurations.fetch(key.to_s, {}).deep_dup
  end

  private

  def configuration_shapes
    errors.add(:enabled_tools, 'must be an array') unless enabled_tools.is_a?(Array)
    errors.add(:tool_configurations, 'must be an object') unless tool_configurations.is_a?(Hash)
    errors.add(:renderer_policy, 'must be an object') unless renderer_policy.is_a?(Hash)
  end

  def enabled_tool_definitions_exist
    return unless enabled_tools.is_a?(Array)

    identifiers = enabled_tools.filter_map do |item|
      unless valid_enabled_tool_item?(item)
        errors.add(:enabled_tools, 'must contain key and version objects')
        next
      end

      identifier = "#{item['key']}@#{item['version']}"
      errors.add(:enabled_tools, "contains unknown Tool #{identifier}") unless ChatRing::Tools::Registry.exist?(item['key'], item['version'])
      identifier
    end
    errors.add(:enabled_tools, 'contains duplicate Tool versions') if identifiers.uniq.length != identifiers.length
  end

  def valid_enabled_tool_item?(item)
    item.is_a?(Hash) && item['key'].present? && item['version'].present?
  end

  def configuration_keys_match_enabled_tools
    return unless enabled_tools.is_a?(Array) && tool_configurations.is_a?(Hash)

    enabled_keys = enabled_tools.filter_map { |item| item['key'].to_s.presence }
    unknown_keys = tool_configurations.keys - enabled_keys
    errors.add(:tool_configurations, "contains disabled Tools: #{unknown_keys.join(', ')}") if unknown_keys.present?
  end

  def tool_configurations_are_valid
    return unless tool_configurations.is_a?(Hash)

    return unless tool_configurations.key?('request_appointment')

    validate_appointment_configuration(tool_configurations['request_appointment'])
  end

  def validate_appointment_configuration(configuration)
    unless configuration.is_a?(Hash)
      errors.add(:tool_configurations, 'request_appointment must be an object')
      return
    end

    provider = configuration['provider'].to_s
    validate_appointment_fields(configuration, provider)
    validate_appointment_url(configuration, provider)
  end

  def validate_appointment_fields(configuration, provider)
    unknown_keys = configuration.keys - APPOINTMENT_CONFIGURATION_KEYS
    errors.add(:tool_configurations, "request_appointment contains unknown settings: #{unknown_keys.join(', ')}") if unknown_keys.present?
    errors.add(:tool_configurations, 'request_appointment provider is invalid') unless PROVIDERS.include?(provider)
    errors.add(:tool_configurations, 'request_appointment fallback is invalid') unless FALLBACK_MODES.include?(configuration['fallback_mode'])
    errors.add(:tool_configurations, 'request_appointment link label is required') if configuration['link_label'].blank?
    errors.add(:tool_configurations, 'request_appointment link label is too long') if configuration['link_label'].to_s.length > 80
  end

  def validate_appointment_url(configuration, provider)
    normalized = ChatRing::Tools::ApprovedPublicUrl.normalize!(configuration['url'], provider: provider)
    configuration['url'] = normalized
  rescue ChatRing::Tools::ApprovedPublicUrl::Invalid => e
    errors.add(:tool_configurations, e.message)
  end

  def published_snapshot_is_immutable
    return if changed_attribute_names_to_save.empty?

    errors.add(:base, 'published Inbox Tool policy version is immutable')
  end
end
