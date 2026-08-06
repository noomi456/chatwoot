require 'faraday'
require 'digest'
require 'securerandom'
require 'uri'

class ChatRing::Knowledge::DocsGptClient
  USER_ID = 'local'.freeze
  DEFAULT_CHUNKS = 5
  MAX_CHUNK_PAGES = 1000
  SOURCE_CONFIG = {
    kind: 'classic',
    chunking: {
      strategy: 'markdown',
      max_tokens: 1250,
      min_tokens: 150,
      duplicate_headers: false
    },
    retrieval: {
      retriever: 'classic',
      exposure: 'prefetch',
      chunks: DEFAULT_CHUNKS,
      rephrase_query: false
    }
  }.freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end

  def initialize(base_url:, jwt_secret:, internal_key:, service_secret:, timeout_seconds: 60)
    @base_url = normalize_base_url(base_url)
    @timeout_seconds = Integer(timeout_seconds)
    @auth = ChatRing::Knowledge::DocsGptAuth.new(
      jwt_secret: jwt_secret,
      internal_key: internal_key,
      service_secret: service_secret
    )
  end

  def upload_version(version) # rubocop:disable Metrics/AbcSize
    documents = version.documents.order(:id).to_a
    raise ResponseError, 'DocsGPT upload requires at least one document' if documents.empty?

    boundary = "----ChatRingKnowledge#{SecureRandom.hex(16)}"
    response = json_connection.post('/api/upload') do |request|
      request.headers.update(@auth.user_headers)
      request.headers['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.headers['Idempotency-Key'] = "chatring-knowledge-version-#{version.id}-#{version.evaluation_binding_digest}"
      request.body = multipart_body(boundary, version, documents)
    end
    parsed = parse_response(response, expected_statuses: [200])
    {
      task_id: required_value(parsed['task_id'], 'DocsGPT upload response is missing task_id'),
      source_id: required_value(parsed['source_id'], 'DocsGPT upload response is missing source_id')
    }
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def task_status(task_id)
    response = json_connection.get('/api/task_status', task_id: task_id) do |request|
      request.headers.update(@auth.user_headers)
    end
    parse_response(response, expected_statuses: [200])
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def chunks(source_id) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    page = 1
    all_chunks = []
    page_fingerprints = Set.new
    loop do
      raise ResponseError, "DocsGPT chunk pagination exceeded #{MAX_CHUNK_PAGES} pages" if page > MAX_CHUNK_PAGES

      response = json_connection.get('/api/get_chunks', id: source_id, page: page, per_page: 100) do |request|
        request.headers.update(@auth.user_headers)
      end
      parsed = parse_response(response, expected_statuses: [200])
      chunks = Array(parsed['chunks'])
      fingerprint = Digest::SHA256.hexdigest(chunks.to_json)
      raise ResponseError, 'DocsGPT chunk pagination repeated a page' if chunks.any? && page_fingerprints.include?(fingerprint)

      page_fingerprints << fingerprint
      all_chunks.concat(chunks)
      break if all_chunks.length >= parsed.fetch('total', all_chunks.length).to_i || chunks.empty?

      page += 1
    end
    all_chunks
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def healthy?
    response = json_connection.get('/api/health') do |request|
      request.headers.update(@auth.user_headers)
    end
    response.status == 200 && JSON.parse(response.body)['status'] == 'ok'
  rescue JSON::ParserError, Faraday::Error
    false
  end

  def delete_source(account_id:, knowledge_version_id:, binding_digest:, source_id:) # rubocop:disable Metrics/MethodLength
    body = { source_id: source_id.to_s }.to_json
    response = json_connection.post('/api/internal/chatring/delete-source') do |request|
      request.headers.update(
        @auth.internal_headers(
          body: body,
          operation: 'delete_source',
          source_id: source_id,
          scope: {
            account_id: account_id,
            knowledge_version_id: knowledge_version_id,
            binding_digest: binding_digest
          }
        )
      )
      request.headers['Content-Type'] = 'application/json'
      request.body = body
    end
    parse_response(response, expected_statuses: [200])
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  private

  def json_connection
    @json_connection ||= Faraday.new(url: @base_url) do |connection|
      connection.options.timeout = @timeout_seconds
      connection.options.open_timeout = [@timeout_seconds, 10].min
      connection.adapter Faraday.default_adapter
    end
  end

  def multipart_body(boundary, version, documents)
    body = String.new(encoding: Encoding::BINARY)
    append_form_part(body, boundary, 'user', USER_ID)
    append_form_part(body, boundary, 'name', source_binding_name(version))
    append_form_part(body, boundary, 'config', SOURCE_CONFIG.to_json)
    documents.each { |document| append_file_part(body, boundary, document) }
    body << "--#{boundary}--\r\n"
  end

  def source_binding_name(version)
    "chatring-a#{version.account_id}-v#{version.id}-#{version.evaluation_binding_digest}"
  end

  def append_form_part(body, boundary, name, value)
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
    body << value.to_s.b << "\r\n"
  end

  def append_file_part(body, boundary, document)
    body << "--#{boundary}\r\n"
    body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{document.provider_file_name}\"\r\n"
    body << "Content-Type: text/markdown\r\n\r\n"
    body << document.markdown.to_s.b << "\r\n"
  end

  def parse_response(response, expected_statuses:)
    raise RequestError, "DocsGPT request failed with HTTP #{response.status}" unless expected_statuses.include?(response.status)

    parsed = JSON.parse(response.body)
    raise ResponseError, 'DocsGPT response must be an object' unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ResponseError, 'DocsGPT response is not valid JSON'
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def normalize_base_url(value)
    raw = value.to_s.strip
    raise ConfigurationError, 'base_url is required' if raw.blank?

    uri = URI.parse(raw)
    raise ConfigurationError, 'base_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    raw.delete_suffix('/')
  rescue URI::InvalidURIError
    raise ConfigurationError, 'base_url is invalid'
  end

  def required_value(value, message)
    result = value.to_s.strip
    raise ResponseError, message if result.blank?

    result
  end
end
