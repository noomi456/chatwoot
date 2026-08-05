require 'digest'
require 'uri'

class ChatRing::Knowledge::DocsGptProvider
  PROVIDER = 'docs_gpt'.freeze
  RETRIEVAL_STRATEGY = 'docs_gpt_api_search'.freeze
  SEARCH_PATH = 'api/search'.freeze
  MAX_RESULTS = 20

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end

  def initialize(base_url:, agent_api_key:, provider_release:, timeout_seconds: 10)
    @base_url = normalize_base_url(base_url)
    @agent_api_key = required_string(agent_api_key, 'agent_api_key')
    @provider_release = required_string(provider_release, 'provider_release')
    @timeout_seconds = positive_integer(timeout_seconds, 'timeout_seconds')
  end

  def retrieve(query:, knowledge_version_id:, source_manifest: nil, source_content_hashes: nil, limit: 5)
    resolved_query = required_string(query, 'query')
    version_id = required_string(knowledge_version_id, 'knowledge_version_id')
    result_limit = result_limit(limit)
    manifest = normalize_manifest(source_manifest || source_content_hashes)
    hits = fetch_hits(resolved_query, result_limit)
    items = hits.each_with_index.map { |hit, index| build_evidence(hit, index + 1, version_id, manifest) }.freeze

    build_evidence_set(version_id, resolved_query, result_limit, items)
  rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError => e
    raise RequestError, "DocsGPT retrieval request failed: #{e.class.name}"
  end

  private

  def fetch_hits(query, limit)
    response = HTTParty.post(
      search_url,
      headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json' },
      body: { question: query, api_key: @agent_api_key, chunks: limit }.to_json,
      timeout: @timeout_seconds
    )
    raise RequestError, "DocsGPT retrieval failed with HTTP #{response.code}" unless response.success?

    hits = response.parsed_response
    raise ResponseError, 'DocsGPT retrieval response must be an array' unless hits.is_a?(Array)

    hits
  end

  def build_evidence_set(version_id, query, limit, items)
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_version_id: version_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      query: query,
      retrieval_strategy: RETRIEVAL_STRATEGY,
      retrieval_configuration: { 'endpoint' => "/#{SEARCH_PATH}", 'limit' => limit }.freeze,
      items: items
    )
  end

  def build_evidence(hit, rank, knowledge_version_id, manifest)
    raise ResponseError, "DocsGPT result #{rank} must be an object" unless hit.is_a?(Hash)

    excerpt = required_response_string(hit['text'], rank, 'text')
    provider_source_id = required_response_string(hit['source'], rank, 'source')
    source = manifest_entry(manifest, provider_source_id, rank)
    title = source['source_title'].presence || hit['title'].to_s.strip

    ChatRing::Knowledge::Evidence.new(
      id: evidence_id(knowledge_version_id, provider_source_id, excerpt),
      knowledge_version_id: knowledge_version_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      provider_source_id: provider_source_id,
      source_reference: source.fetch('source_reference'),
      source_title: title.presence,
      locator: source['locator'].presence || title.presence || source.fetch('source_reference'),
      excerpt: excerpt,
      source_content_hash: source.fetch('content_hash'),
      rank: rank,
      score: nil,
      retrieval_strategy: RETRIEVAL_STRATEGY
    )
  end

  def manifest_entry(manifest, provider_source_id, rank)
    source = manifest[provider_source_id]
    return source if source.present?

    raise ResponseError, "DocsGPT result #{rank} references a source outside the knowledge-version manifest"
  end

  def normalize_manifest(value)
    value.to_h.transform_keys(&:to_s).transform_values do |entry|
      if entry.is_a?(Hash)
        normalized = entry.deep_stringify_keys
        normalized['content_hash'] = required_string(normalized['content_hash'], 'source content_hash')
        normalized['source_reference'] = required_string(normalized['source_reference'], 'source source_reference')
        normalized
      else
        {
          'content_hash' => required_string(entry, 'source content_hash'),
          'source_reference' => nil
        }
      end
    end.tap do |manifest|
      manifest.each do |provider_source_id, entry|
        entry['source_reference'] ||= provider_source_id
      end
    end
  end

  def evidence_id(knowledge_version_id, provider_source_id, excerpt)
    Digest::SHA256.hexdigest([knowledge_version_id, @provider_release, provider_source_id, excerpt].join("\0"))
  end

  def search_url
    URI.join("#{@base_url}/", SEARCH_PATH).to_s
  end

  def normalize_base_url(base_url)
    value = required_string(base_url, 'base_url')
    uri = URI.parse(value)
    raise ConfigurationError, 'base_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    value.delete_suffix('/')
  rescue URI::InvalidURIError
    raise ConfigurationError, 'base_url is invalid'
  end

  def required_string(value, name)
    result = value.to_s.strip
    raise ConfigurationError, "#{name} is required" if result.blank?

    result
  end

  def required_response_string(value, rank, field)
    result = value.to_s.strip
    raise ResponseError, "DocsGPT result #{rank} is missing #{field}" if result.blank?

    result
  end

  def positive_integer(value, name)
    result = Integer(value)
    raise ConfigurationError, "#{name} must be positive" unless result.positive?

    result
  rescue ArgumentError, TypeError
    raise ConfigurationError, "#{name} must be an integer"
  end

  def result_limit(value)
    limit = positive_integer(value, 'limit')
    raise ConfigurationError, "limit must be between 1 and #{MAX_RESULTS}" if limit > MAX_RESULTS

    limit
  end
end
