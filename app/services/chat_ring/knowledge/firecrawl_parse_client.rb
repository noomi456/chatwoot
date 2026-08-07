require 'digest'
require 'faraday'
require 'faraday/multipart'
require 'json'
require 'uri'

class ChatRing::Knowledge::FirecrawlParseClient
  DEFAULT_BASE_URL = 'https://api.firecrawl.dev'.freeze
  MAX_TIMEOUT_MS = 300_000
  MAX_PDF_PAGES = 200
  PROFILE_VERSION = 1

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ResponseError < Error; end

  class RequestError < Error
    attr_reader :http_status

    def initialize(message, http_status: nil, indeterminate: true)
      super(message)
      @http_status = http_status
      @indeterminate = indeterminate
    end

    def indeterminate?
      @indeterminate
    end
  end

  def self.profile_for(source_kind)
    profile = {
      'profile_version' => PROFILE_VERSION,
      'formats' => ['markdown'],
      'onlyMainContent' => true,
      'removeBase64Images' => true,
      'zeroDataRetention' => zero_data_retention?,
      'timeout' => MAX_TIMEOUT_MS
    }
    profile['parsers'] = [{ 'type' => 'pdf', 'mode' => 'auto', 'maxPages' => MAX_PDF_PAGES }] if source_kind.to_s == 'pdf'
    profile.freeze
  end

  def self.profile_digest(source_kind)
    Digest::SHA256.hexdigest(profile_for(source_kind).to_json)
  end

  def self.zero_data_retention?
    ENV.fetch('FIRECRAWL_ZERO_DATA_RETENTION', 'false').casecmp?('true')
  end

  def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout_seconds: 310)
    @api_key = required_string(api_key, 'api_key')
    @base_url = normalize_base_url(base_url)
    @timeout_seconds = Integer(timeout_seconds)
  end

  def parse(path:, filename:, content_type:, source_kind:, profile: nil)
    profile ||= self.class.profile_for(source_kind)
    response = connection.post('/v2/parse') do |request|
      request.headers['Authorization'] = "Bearer #{@api_key}"
      request.headers['Accept'] = 'application/json'
      request.body = {
        file: Faraday::Multipart::FilePart.new(path, content_type, filename),
        options: Faraday::Multipart::ParamPart.new(profile.except('profile_version').to_json, 'application/json')
      }
    end
    validate_response(response)
  rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
    raise RequestError.new("Firecrawl Parse transport failed: #{e.class.name}", indeterminate: true)
  rescue Faraday::Error => e
    raise RequestError.new("Firecrawl Parse request failed: #{e.class.name}", indeterminate: true)
  end

  private

  def connection
    @connection ||= Faraday.new(url: @base_url) do |connection|
      connection.request :multipart
      connection.request :url_encoded
      connection.options.timeout = @timeout_seconds
      connection.options.open_timeout = 10
      connection.adapter Faraday.default_adapter
    end
  end

  def validate_response(response)
    unless response.status.between?(200, 299)
      indeterminate = response.status >= 500
      raise RequestError.new(
        "Firecrawl Parse failed with HTTP #{response.status}",
        http_status: response.status,
        indeterminate: indeterminate
      )
    end

    payload = JSON.parse(response.body)
    data = payload['data']
    unless payload['success'] == true && data.is_a?(Hash) && data['markdown'].to_s.present?
      raise ResponseError, 'Firecrawl Parse response is missing Markdown'
    end

    { 'markdown' => data['markdown'].to_s, 'metadata' => data['metadata'].is_a?(Hash) ? data['metadata'] : {} }
  rescue JSON::ParserError
    raise ResponseError, 'Firecrawl Parse response is not valid JSON'
  end

  def normalize_base_url(value)
    raw = required_string(value, 'base_url')
    uri = URI.parse(raw)
    raise ConfigurationError, 'base_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    raw.delete_suffix('/')
  rescue URI::InvalidURIError
    raise ConfigurationError, 'base_url is invalid'
  end

  def required_string(value, name)
    result = value.to_s.strip
    raise ConfigurationError, "#{name} is required" if result.blank?

    result
  end
end
