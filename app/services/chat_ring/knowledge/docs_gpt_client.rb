require 'faraday'
require 'faraday/multipart'
require 'tempfile'
require 'uri'

class ChatRing::Knowledge::DocsGptClient
  USER_ID = 'local'.freeze
  DEFAULT_CHUNKS = 5
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

  def initialize(base_url:, timeout_seconds: 60)
    @base_url = normalize_base_url(base_url)
    @timeout_seconds = Integer(timeout_seconds)
  end

  def upload_document(document)
    Tempfile.create(['chatring-knowledge-', '.md']) do |file|
      file.binmode
      file.write(document.markdown)
      file.flush
      part = Faraday::Multipart::FilePart.new(file.path, 'text/markdown', document.provider_file_name)
      response = multipart_connection.post('/api/upload') do |request|
        request.headers['Idempotency-Key'] = "chatring-knowledge-document-#{document.id}-#{document.content_hash}"
        request.body = {
          user: USER_ID,
          name: "chatring-version-#{document.knowledge_version_id}-document-#{document.id}",
          config: SOURCE_CONFIG.to_json,
          file: part
        }
      end
      parsed = parse_response(response, expected_statuses: [200])
      {
        task_id: required_value(parsed['task_id'], 'DocsGPT upload response is missing task_id'),
        source_id: required_value(parsed['source_id'], 'DocsGPT upload response is missing source_id')
      }
    end
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def task_status(task_id)
    response = json_connection.get('/api/task_status', task_id: task_id)
    parse_response(response, expected_statuses: [200])
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def chunks(source_id)
    page = 1
    all_chunks = []
    loop do
      response = json_connection.get('/api/get_chunks', id: source_id, page: page, per_page: 100)
      parsed = parse_response(response, expected_statuses: [200])
      chunks = Array(parsed['chunks'])
      all_chunks.concat(chunks)
      break if all_chunks.length >= parsed.fetch('total', all_chunks.length).to_i || chunks.empty?

      page += 1
    end
    all_chunks
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def create_agent(version)
    source_ids = version.documents.order(:id).pluck(:provider_source_id)
    raise ResponseError, 'DocsGPT agent requires at least one ingested source' if source_ids.empty? || source_ids.any?(&:blank?)

    response = json_connection.post('/api/create_agent') do |request|
      request.headers['Content-Type'] = 'application/json'
      request.body = {
        name: "ChatRing Knowledge Version #{version.id}",
        description: "ChatRing published evidence corpus #{version.id}",
        sources: source_ids,
        chunks: DEFAULT_CHUNKS,
        retriever: 'classic',
        prompt_id: 'default',
        agent_type: 'classic',
        status: 'published'
      }.to_json
    end
    parsed = parse_response(response, expected_statuses: [201])
    {
      id: required_value(parsed['id'], 'DocsGPT create-agent response is missing id'),
      key: required_value(parsed['key'], 'DocsGPT create-agent response is missing key')
    }
  rescue Faraday::Error => e
    raise RequestError, "DocsGPT request failed: #{e.class.name}"
  end

  def healthy?
    response = json_connection.get('/api/health')
    response.status == 200 && JSON.parse(response.body)['status'] == 'ok'
  rescue JSON::ParserError, Faraday::Error
    false
  end

  private

  def json_connection
    @json_connection ||= Faraday.new(url: @base_url) do |connection|
      connection.options.timeout = @timeout_seconds
      connection.options.open_timeout = [@timeout_seconds, 10].min
      connection.adapter Faraday.default_adapter
    end
  end

  def multipart_connection
    @multipart_connection ||= Faraday.new(url: @base_url) do |connection|
      connection.request :multipart
      connection.options.timeout = @timeout_seconds
      connection.options.open_timeout = [@timeout_seconds, 10].min
      connection.adapter Faraday.default_adapter
    end
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
