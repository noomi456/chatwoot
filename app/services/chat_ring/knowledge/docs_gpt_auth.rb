require 'digest'
require 'openssl'

class ChatRing::Knowledge::DocsGptAuth
  TOKEN_TTL = 5.minutes

  class ConfigurationError < StandardError; end

  def initialize(jwt_secret: nil, internal_key: nil, service_secret: nil)
    @jwt_secret = jwt_secret.to_s
    @internal_key = internal_key.to_s
    @service_secret = service_secret.to_s
  end

  def user_headers
    required_secret(@jwt_secret, 'jwt_secret')
    now = Time.current.to_i
    token = JWT.encode({ sub: 'local', iat: now, exp: now + TOKEN_TTL.to_i }, @jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def internal_headers(body:, account_id:, knowledge_version_id:, operation:, source_id:)
    required_secret(@internal_key, 'internal_key')
    required_secret(@service_secret, 'service_secret')
    timestamp = Time.current.to_i.to_s
    values = [
      timestamp,
      account_id.to_s,
      knowledge_version_id.to_s,
      operation.to_s,
      source_id.to_s,
      Digest::SHA256.hexdigest(body)
    ]
    signature = OpenSSL::HMAC.hexdigest('SHA256', @service_secret, values.join("\n"))

    {
      'X-Internal-Key' => @internal_key,
      'X-ChatRing-Timestamp' => timestamp,
      'X-ChatRing-Account' => account_id.to_s,
      'X-ChatRing-Knowledge-Version' => knowledge_version_id.to_s,
      'X-ChatRing-Signature' => signature
    }
  end

  private

  def required_secret(value, name)
    raise ConfigurationError, "#{name} is required" if value.to_s.blank?
  end
end
