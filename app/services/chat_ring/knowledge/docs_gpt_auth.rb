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

  def internal_headers(body:, operation:, source_id:, scope:)
    required_secret(@internal_key, 'internal_key')
    required_secret(@service_secret, 'service_secret')
    values = scope.symbolize_keys
    timestamp = Time.current.to_i.to_s
    signature = scoped_signature(body: body, operation: operation, source_id: source_id, scope: values, timestamp: timestamp)

    {
      'X-Internal-Key' => @internal_key,
      'X-ChatRing-Timestamp' => timestamp,
      'X-ChatRing-Account' => values.fetch(:account_id).to_s,
      'X-ChatRing-Knowledge-Version' => values.fetch(:knowledge_version_id).to_s,
      'X-ChatRing-Binding-Digest' => values.fetch(:binding_digest).to_s,
      'X-ChatRing-Signature' => signature
    }
  end

  private

  def scoped_signature(body:, operation:, source_id:, scope:, timestamp:)
    values = [
      timestamp,
      scope.fetch(:account_id),
      scope.fetch(:knowledge_version_id),
      scope.fetch(:binding_digest),
      operation,
      source_id,
      Digest::SHA256.hexdigest(body)
    ]
    OpenSSL::HMAC.hexdigest('SHA256', @service_secret, values.join("\n"))
  end

  def required_secret(value, name)
    raise ConfigurationError, "#{name} is required" if value.to_s.blank?
  end
end
