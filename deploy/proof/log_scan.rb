# frozen_string_literal: true

require 'digest'
require 'json'

SECRET_ENV_NAMES = %w[
  CHATRING_LLM_API_KEY
  DOCSGPT_INTERNAL_KEY
  DOCSGPT_JWT_SECRET
  DOCSGPT_SERVICE_SECRET
  POSTGRES_PASSWORD
  REDIS_PASSWORD
  SECRET_KEY_BASE
].freeze
FAILURE_PATTERNS = [
  /(^|[^A-Za-z])FATAL([^A-Za-z]|$)/,
  /NoMethodError/,
  /ActiveRecord::StatementInvalid/,
  /uninitialized constant/
].freeze

data = $stdin.read
secrets = SECRET_ENV_NAMES.filter_map do |name|
  value = ENV[name].to_s
  value unless value.empty?
end
abort 'proof logs contain a configured secret' if secrets.any? { |secret| data.include?(secret) }
abort 'proof logs contain a raw proof message' if data.include?('[[PROOF_')
abort 'proof logs contain an unexpected runtime failure' if FAILURE_PATTERNS.any? { |pattern| data.match?(pattern) }

result = {
  scanned_bytes: data.bytesize,
  sha256: Digest::SHA256.hexdigest(data),
  configured_secrets_absent: true,
  raw_proof_messages_absent: true,
  unexpected_runtime_failures_absent: true
}
path = File.join(ENV.fetch('PROOF_STATE_DIR', '/proof-state'), 'log_scan.json')
File.write(path, JSON.pretty_generate(result))
File.chmod(0o600, path)
$stdout.write(JSON.generate(result))
