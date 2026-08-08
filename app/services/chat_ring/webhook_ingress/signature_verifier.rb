class ChatRing::WebhookIngress::SignatureVerifier
  REPLAY_WINDOW = 5.minutes
  SHA256_SIGNATURE = /\Asha256=([0-9a-f]{64})\z/

  class VerificationError < StandardError; end

  def initialize(secret:, raw_body:, timestamp:, signature:, now: Time.current)
    @secret = secret
    @raw_body = raw_body
    @timestamp = timestamp
    @signature = signature
    @now = now
  end

  def verify!
    raise VerificationError, 'missing webhook secret' if secret.blank?

    timestamp_value = parse_timestamp!
    raise VerificationError, 'webhook timestamp outside replay window' if (now.to_i - timestamp_value).abs > REPLAY_WINDOW.to_i

    supplied_digest = signature.to_s.match(SHA256_SIGNATURE)&.captures&.first
    raise VerificationError, 'malformed webhook signature' if supplied_digest.blank?

    expected_digest = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{raw_body}")
    return true if ActiveSupport::SecurityUtils.secure_compare(expected_digest, supplied_digest)

    raise VerificationError, 'invalid webhook signature'
  end

  private

  attr_reader :secret, :raw_body, :timestamp, :signature, :now

  def parse_timestamp!
    Integer(timestamp, 10)
  rescue ArgumentError, TypeError
    raise VerificationError, 'malformed webhook timestamp'
  end
end
