require 'digest'
require 'httparty'
require 'openssl'
require 'uri'

class ChatRing::Knowledge::FirecrawlClient
  DEFAULT_BASE_URL = 'https://api.firecrawl.dev'.freeze
  DEFAULT_MAP_LIMIT = 5000
  MAX_URLS = 100_000
  MAX_BATCH_PAGES = 10_000

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end

  def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout_seconds: 30)
    @api_key = required_string(api_key, 'api_key')
    @base_uri = validated_base_uri(base_url)
    @timeout_seconds = Integer(timeout_seconds)
  end

  def map(url:, limit: DEFAULT_MAP_LIMIT) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    root_url = canonical_url(url)
    resolved_limit = bounded_limit(limit)
    payload = request_json(
      :post,
      '/v2/map',
      body: {
        url: root_url,
        limit: resolved_limit,
        includeSubdomains: false,
        ignoreQueryParameters: true
      }
    )
    links = payload.fetch('links') { raise ResponseError, 'Firecrawl map response is missing links' }
    raise ResponseError, 'Firecrawl map links must be an array' unless links.is_a?(Array)
    if links.length >= resolved_limit
      raise ResponseError, "Firecrawl map reached the configured ceiling of #{resolved_limit} URLs; completeness is unknown"
    end

    normalized = links.filter_map { |entry| normalize_map_entry(entry) }
    normalized << { 'url' => root_url } unless normalized.any? { |entry| entry['url'] == root_url }
    normalized.uniq { |entry| entry['url'] }.sort_by { |entry| entry['url'] }
  end

  def start_batch_scrape(urls:)
    normalized_urls = Array(urls).map { |url| canonical_url(url) }.uniq
    raise ConfigurationError, 'urls must contain at least one URL' if normalized_urls.empty?

    bounded_limit(normalized_urls.length)
    payload = request_json(
      :post,
      '/v2/batch/scrape',
      body: {
        urls: normalized_urls,
        ignoreInvalidURLs: false,
        formats: ['markdown'],
        onlyMainContent: true
      }
    )
    required_response_string(payload['id'], 'Firecrawl batch-scrape response is missing id')
  end

  def batch_status(batch_id)
    first_page = request_json(:get, "/v2/batch/scrape/#{escape_segment(batch_id)}")
    return first_page unless first_page['status'] == 'completed'

    data = Array(first_page['data'])
    next_url = first_page['next']
    seen_pages = Set.new
    page_count = 1
    while next_url.present?
      page_url = validated_next_url(next_url)
      raise ResponseError, 'Firecrawl pagination URL repeated; refusing to loop indefinitely' unless seen_pages.add?(page_url)
      raise ResponseError, "Firecrawl batch exceeded #{MAX_BATCH_PAGES} pages" if page_count >= MAX_BATCH_PAGES

      page = request_json(:get, page_url)
      data.concat(Array(page['data']))
      next_url = page['next']
      page_count += 1
    end
    first_page.merge('data' => data, 'next' => nil)
  end

  def batch_errors(batch_id)
    request_json(:get, "/v2/batch/scrape/#{escape_segment(batch_id)}/errors")
  end

  def self.canonical_url(value)
    uri = URI.parse(value.to_s.strip)
    raise ConfigurationError, 'URL must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.fragment = nil
    uri.query = nil
    uri.host = uri.host.downcase
    uri.path = '/' if uri.path.blank?
    uri.path = uri.path.delete_suffix('/') unless uri.path == '/'
    uri.to_s
  rescue URI::InvalidURIError
    raise ConfigurationError, 'URL is invalid'
  end

  private

  def request_json(method, path_or_url, body: nil)
    url = path_or_url.to_s.start_with?('http') ? path_or_url.to_s : URI.join(@base_uri.to_s, path_or_url.to_s).to_s
    options = {
      headers: {
        'Authorization' => "Bearer #{@api_key}",
        'Accept' => 'application/json',
        'Content-Type' => 'application/json'
      },
      timeout: @timeout_seconds
    }
    options[:body] = body.to_json if body
    response = HTTParty.public_send(method, url, options)
    raise RequestError, "Firecrawl request failed with HTTP #{response.code}" unless response.success?

    parsed = response.parsed_response
    raise ResponseError, 'Firecrawl response must be an object' unless parsed.is_a?(Hash)

    parsed
  rescue Timeout::Error, SocketError, EOFError, HTTParty::Error, Errno::ECONNABORTED, Errno::ECONNREFUSED,
         Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE, Errno::ETIMEDOUT,
         OpenSSL::SSL::SSLError => e
    raise RequestError, "Firecrawl request failed: #{e.class.name}"
  end

  def normalize_map_entry(entry)
    value = entry.is_a?(Hash) ? entry['url'] : entry
    return if value.blank?

    {
      'url' => canonical_url(value),
      'title' => entry.is_a?(Hash) ? entry['title'].to_s.presence : nil,
      'description' => entry.is_a?(Hash) ? entry['description'].to_s.presence : nil
    }.compact
  end

  def canonical_url(value)
    self.class.canonical_url(value)
  end

  def validated_base_uri(value)
    uri = URI.parse("#{required_string(value, 'base_url').delete_suffix('/')}/")
    raise ConfigurationError, 'base_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri
  rescue URI::InvalidURIError
    raise ConfigurationError, 'base_url is invalid'
  end

  def validated_next_url(value)
    uri = URI.parse(value.to_s)
    unless uri.is_a?(URI::HTTP) && uri.scheme == @base_uri.scheme && uri.host == @base_uri.host && uri.port == @base_uri.port
      raise ResponseError, 'Firecrawl pagination URL is outside the configured API origin'
    end

    uri.to_s
  rescue URI::InvalidURIError
    raise ResponseError, 'Firecrawl pagination URL is invalid'
  end

  def bounded_limit(value)
    limit = Integer(value)
    raise ConfigurationError, "limit must be between 1 and #{MAX_URLS}" unless limit.between?(1, MAX_URLS)

    limit
  rescue ArgumentError, TypeError
    raise ConfigurationError, 'limit must be an integer'
  end

  def escape_segment(value)
    URI.encode_www_form_component(required_string(value, 'crawl_id'))
  end

  def required_string(value, name)
    result = value.to_s.strip
    raise ConfigurationError, "#{name} is required" if result.blank?

    result
  end

  def required_response_string(value, message)
    result = value.to_s.strip
    raise ResponseError, message if result.blank?

    result
  end
end
