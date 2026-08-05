require 'digest'
require 'httparty'
require 'uri'

class ChatRing::Knowledge::FirecrawlClient
  DEFAULT_BASE_URL = 'https://api.firecrawl.dev'.freeze
  MAX_URLS = 100

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end

  def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout_seconds: 30)
    @api_key = required_string(api_key, 'api_key')
    @base_uri = validated_base_uri(base_url)
    @timeout_seconds = Integer(timeout_seconds)
  end

  def map(url:, limit: MAX_URLS)
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

    normalized = links.filter_map { |entry| normalize_map_entry(entry) }
    normalized << { 'url' => root_url } unless normalized.any? { |entry| entry['url'] == root_url }
    normalized.uniq { |entry| entry['url'] }.sort_by { |entry| entry['url'] }.first(resolved_limit)
  end

  def start_crawl(url:, limit: MAX_URLS)
    payload = request_json(
      :post,
      '/v2/crawl',
      body: {
        url: canonical_url(url),
        limit: bounded_limit(limit),
        crawlEntireDomain: true,
        allowSubdomains: false,
        allowExternalLinks: false,
        ignoreQueryParameters: true,
        scrapeOptions: {
          formats: ['markdown'],
          onlyMainContent: true
        }
      }
    )
    required_response_string(payload['id'], 'Firecrawl crawl response is missing id')
  end

  def crawl_status(crawl_id)
    first_page = request_json(:get, "/v2/crawl/#{escape_segment(crawl_id)}")
    return first_page unless first_page['status'] == 'completed'

    data = Array(first_page['data'])
    next_url = first_page['next']
    while next_url.present?
      page = request_json(:get, validated_next_url(next_url))
      data.concat(Array(page['data']))
      next_url = page['next']
    end
    first_page.merge('data' => data, 'next' => nil)
  end

  def crawl_errors(crawl_id)
    request_json(:get, "/v2/crawl/#{escape_segment(crawl_id)}/errors")
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
  rescue Timeout::Error, SocketError => e
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
