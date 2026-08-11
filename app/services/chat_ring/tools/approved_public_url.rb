require 'ipaddr'
require 'public_suffix'
require 'uri'

class ChatRing::Tools::ApprovedPublicUrl
  class Invalid < StandardError; end

  MAX_LENGTH = 2048

  PROVIDER_HOSTS = {
    'calendly' => /\A(?:[a-z0-9-]+\.)*calendly\.com\z/i,
    'calcom' => /\A(?:[a-z0-9-]+\.)*cal\.com\z/i
  }.freeze

  def self.normalize!(value, provider:)
    uri = parse_https_uri!(value)
    validate_public_host!(uri)
    validate_provider_host!(uri, provider)

    uri.fragment = nil
    uri.normalize.to_s
  end

  def self.parse_https_uri!(value)
    raw_value = value.to_s.strip
    raise Invalid, 'Calendar URL is too long' if raw_value.length > MAX_LENGTH

    URI.parse(raw_value).tap do |uri|
      raise Invalid, 'Calendar URL must use HTTPS' unless uri.is_a?(URI::HTTPS)
    end
  rescue URI::InvalidURIError
    raise Invalid, 'Calendar URL is invalid'
  end

  def self.validate_public_host!(uri)
    hostname = uri.hostname.to_s.downcase.delete_suffix('.')
    raise Invalid, 'Calendar URL cannot contain credentials' if uri.userinfo.present?
    raise Invalid, 'Calendar URL requires a public hostname' if hostname.blank? || non_public_host?(hostname)

    uri.host = hostname
  end

  def self.validate_provider_host!(uri, provider)
    provider_pattern = PROVIDER_HOSTS[provider.to_s]
    return unless provider_pattern && !uri.host.match?(provider_pattern)

    raise Invalid, "Calendar URL does not match #{provider}"
  end

  def self.non_public_host?(host)
    ip_address?(host) || !PublicSuffix.valid?(host)
  end

  def self.ip_address?(host)
    IPAddr.new(host)
    true
  rescue IPAddr::InvalidAddressError
    false
  end
  private_class_method :ip_address?, :non_public_host?, :parse_https_uri!, :validate_provider_host!, :validate_public_host!
end
