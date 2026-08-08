require 'faraday'
require 'digest'
require 'securerandom'
require 'uri'

class ChatRing::Knowledge::DocsGptClient # rubocop:disable Metrics/ClassLength
  USER_ID = 'local'.freeze
  DEFAULT_CHUNKS = ChatRing::Knowledge::DocsGptProvider::DEFAULT_EVIDENCE_LIMIT
  MAX_CHUNK_PAGES = 1000
  INGEST_NAMESPACE = ['fa25d5d1398b46dfac898d1c360b9bea'].pack('H*').freeze
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

  def upload_index(index) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    documents = index.documents.order(:id).to_a
    raise ResponseError, 'DocsGPT upload requires at least one document' if documents.empty?

    boundary = "----ChatRingKnowledge#{SecureRandom.hex(16)}"
    body = multipart_body(boundary, index, documents)
    source_name = source_binding_name(index)
    response = json_connection.post('/api/internal/chatring/upload') do |request|
      request.headers.update(internal_headers(index, body, 'upload_index', source_name))
      request.headers['X-ChatRing-Provider-Source'] = source_name
      request.headers['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      request.headers['Idempotency-Key'] = upload_idempotency_key(index)
      request.body = body
    end
    parsed = parse_response(response, expected_statuses: [200])
    source_id = required_value(parsed['source_id'], 'DocsGPT upload response is missing source_id')
    raise ResponseError, 'DocsGPT upload returned an unexpected source_id' unless source_id == expected_source_id(index)

    {
      task_id: required_value(parsed['task_id'], 'DocsGPT upload response is missing task_id'),
      source_id: source_id
    }
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def task_status(index, task_id, source_id)
    response = json_connection.get('/api/internal/chatring/task-status', task_id: task_id, source_id: source_id) do |request|
      request.headers.update(internal_headers(index, '', 'task_status', source_id))
    end
    parse_response(response, expected_statuses: [200])
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def chunks(index, source_id) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    page = 1
    all_chunks = []
    page_fingerprints = Set.new
    loop do
      raise ResponseError, "DocsGPT chunk pagination exceeded #{MAX_CHUNK_PAGES} pages" if page > MAX_CHUNK_PAGES

      response = json_connection.get(
        '/api/internal/chatring/chunks',
        source_id: source_id,
        id: source_id,
        page: page,
        per_page: 100
      ) do |request|
        request.headers.update(internal_headers(index, '', 'inspect_chunks', source_id))
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

  def expected_source_id(index)
    uuid_v5(INGEST_NAMESPACE, "#{USER_ID}:#{upload_idempotency_key(index)}")
  end

  def delete_source(account_id:, knowledge_index_id:, binding_digest:, source_id:) # rubocop:disable Metrics/MethodLength
    body = { source_id: source_id.to_s }.to_json
    response = json_connection.post('/api/internal/chatring/delete-source') do |request|
      request.headers.update(
        @auth.internal_headers(
          body: body,
          operation: 'delete_source',
          source_id: source_id,
          scope: {
            account_id: account_id,
            knowledge_index_id: knowledge_index_id,
            binding_digest: binding_digest
          }
        )
      )
      request.headers['Content-Type'] = 'application/json'
      request.body = body
    end
    parsed = parse_response(response, expected_statuses: [200])
    unless %w[deleted already_absent].include?(parsed['status']) && parsed['source_id'].to_s == source_id.to_s
      raise ResponseError, 'DocsGPT deletion response is invalid'
    end

    parsed
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  private

  def internal_headers(index, body, operation, source_id)
    @auth.internal_headers(
      body: body,
      operation: operation,
      source_id: source_id,
      scope: {
        account_id: index.account_id,
        knowledge_index_id: index.id,
        binding_digest: index.provider_binding_digest
      }
    )
  end

  def upload_idempotency_key(index)
    "chatring-knowledge-index-#{index.id}-#{index.provider_binding_digest}"
  end

  def uuid_v5(namespace_bytes, value)
    bytes = Digest::SHA1.digest(namespace_bytes + value.to_s.b).bytes.first(16)
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    hex = bytes.pack('C*').unpack1('H*')
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
  end

  def json_connection
    @json_connection ||= Faraday.new(url: @base_url) do |connection|
      connection.options.timeout = @timeout_seconds
      connection.options.open_timeout = [@timeout_seconds, 10].min
      connection.adapter Faraday.default_adapter
    end
  end

  def multipart_body(boundary, index, documents)
    body = String.new(encoding: Encoding::BINARY)
    append_form_part(body, boundary, 'user', USER_ID)
    append_form_part(body, boundary, 'name', source_binding_name(index))
    append_form_part(body, boundary, 'config', SOURCE_CONFIG.to_json)
    documents.each { |document| append_file_part(body, boundary, document) }
    body << "--#{boundary}--\r\n"
  end

  def source_binding_name(index)
    "chatring-a#{index.account_id}-i#{index.id}-#{index.provider_binding_digest}"
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
