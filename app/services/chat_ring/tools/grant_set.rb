class ChatRing::Tools::GrantSet
  class Invalid < StandardError; end

  attr_reader :entries

  def initialize(items)
    raise Invalid, 'Tool grants must be an array' unless items.is_a?(Array)

    @entries = items.map { |item| normalize(item) }.freeze
    raise Invalid, 'Tool grants contain duplicates' unless entries.map { |item| item.values_at('key', 'version') }.uniq.length == entries.length
  end

  def include?(key, version)
    entries.any? { |item| item['key'] == key.to_s && item['version'] == version.to_i }
  end

  private

  def normalize(item)
    raise Invalid, 'Tool grants must contain key and version objects' unless item.is_a?(Hash)

    attributes = item.deep_stringify_keys
    raise Invalid, 'Tool grants contain unknown fields' unless (attributes.keys - %w[key version]).empty?

    key = attributes.fetch('key').to_s
    version = Integer(attributes.fetch('version'))
    ChatRing::Tools::Registry.fetch(key, version)
    { 'key' => key, 'version' => version }.freeze
  rescue KeyError, ArgumentError, TypeError
    raise Invalid, 'Tool grants contain an unknown Tool version'
  end
end
