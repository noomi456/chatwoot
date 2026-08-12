require 'digest'
require 'httparty'
require 'net/http'
require 'openssl'
require 'uri'

# rubocop:disable Metrics/ClassLength
class ChatRing::Knowledge::DocsGptProvider
  PROVIDER = 'docs_gpt'.freeze
  RETRIEVAL_STRATEGY = 'docs_gpt_dispatcher_classic_exact_candidates'.freeze
  LEGACY_RETRIEVAL_STRATEGY = 'docs_gpt_dispatcher_classic_cosine'.freeze
  RETRIEVAL_PATH = '/api/internal/chatring/retrieve'.freeze
  DEFAULT_EVIDENCE_LIMIT = 8
  MAX_RESULTS = 20
  MAX_QUERY_LENGTH = 2000

  class Error < StandardError; end
  class ConfigurationError < Error; end

  class RemoteError < Error
    attr_reader :error_code

    def initialize(message, error_code:)
      super(message)
      @error_code = error_code
    end
  end

  class RequestError < RemoteError
    def initialize(message, error_code: 'provider_connection_failed')
      super
    end
  end

  class ResponseError < RemoteError
    def initialize(message, error_code: 'provider_invalid_response')
      super
    end
  end

  class IntegrityError < ResponseError
    def initialize(message, error_code: 'provider_integrity_error')
      super
    end
  end

  # rubocop:disable Metrics/ParameterLists
  def initialize(base_url:, provider_release:, provider_source_id:, account_id:, binding_digest:, internal_key:,
                 service_secret:, retrieval_configuration:, timeout_seconds: 10)
    @base_url = normalize_base_url(base_url)
    @provider_release = required_string(provider_release, 'provider_release')
    @provider_source_id = required_string(provider_source_id, 'provider_source_id')
    @account_id = required_string(account_id, 'account_id')
    @binding_digest = sha256_digest(binding_digest, 'binding_digest')
    @retrieval_strategy, @score_threshold = normalize_retrieval_configuration(retrieval_configuration)
    @timeout_seconds = positive_integer(timeout_seconds, 'timeout_seconds')
    @auth = ChatRing::Knowledge::DocsGptAuth.new(
      internal_key: internal_key,
      service_secret: service_secret
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def retrieve(query:, knowledge_index_id:, source_manifest:, limit: DEFAULT_EVIDENCE_LIMIT) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    resolved_query = required_string(query, 'query')
    raise ConfigurationError, "query must not exceed #{MAX_QUERY_LENGTH} characters" if resolved_query.length > MAX_QUERY_LENGTH

    index_id = required_string(knowledge_index_id, 'knowledge_index_id')
    result_limit = result_limit(limit)
    manifest = normalize_manifest(source_manifest)
    body = {
      query: resolved_query,
      source_id: @provider_source_id,
      # Fetch a bounded superset so a newly tombstoned or Assistant-scoped
      # top hit cannot hide still-valid evidence ranked just below it.
      limit: MAX_RESULTS
    }.to_json
    payload = fetch_payload(body, index_id)
    status = required_status(payload)
    items = if status == 'accepted'
              filter_candidates(build_items(payload, index_id, manifest, resolved_query)).first(result_limit)
            else
              []
            end
    status = 'insufficient_evidence' if status == 'accepted' && items.empty?
    build_evidence_set(index_id, resolved_query, result_limit, payload, status, items)
  rescue RequestError, ResponseError => e
    log_provider_failure(e.error_code, e)
    failure_set(index_id, resolved_query, result_limit, 'provider_error', e.error_code)
  rescue Timeout::Error => e
    log_provider_failure('provider_timeout', e)
    failure_set(index_id, resolved_query, result_limit, 'provider_error', 'provider_timeout')
  rescue SocketError, EOFError, Errno::ECONNABORTED, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
         Errno::ENETUNREACH, Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
    log_provider_failure('provider_connection_failed', e)
    failure_set(index_id, resolved_query, result_limit, 'provider_error', 'provider_connection_failed')
  rescue HTTParty::Error, JSON::ParserError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
    log_provider_failure('provider_invalid_response', e)
    failure_set(index_id, resolved_query, result_limit, 'provider_error', 'provider_invalid_response')
  end

  private

  def fetch_payload(body, index_id)
    headers = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json'
    }.merge(auth_headers(body, index_id))
    response = HTTParty.post(retrieval_url, headers: headers, body: body, timeout: @timeout_seconds)
    raise request_error(response.code) unless response.success? || response.code == 503

    parsed = response.parsed_response
    unless parsed.is_a?(Hash)
      error_code = response.code == 503 ? 'provider_unavailable' : 'provider_invalid_response'
      raise ResponseError.new("DocsGPT retrieval response is invalid (HTTP #{response.code})", error_code: error_code)
    end

    if response.code == 503
      parsed['status'] = 'provider_error'
      parsed['chatring_error_code'] = 'provider_unavailable'
      return parsed
    end

    parsed
  end

  def request_error(status)
    error_code = case status
                 when 401, 403 then 'provider_authentication_failed'
                 when 404 then 'provider_source_missing'
                 when 429 then 'provider_rate_limited'
                 when 500..599 then 'provider_unavailable'
                 else 'provider_invalid_response'
                 end
    RequestError.new("DocsGPT retrieval failed with HTTP #{status}", error_code: error_code)
  end

  def auth_headers(body, index_id)
    @auth.internal_headers(
      body: body,
      operation: 'retrieve',
      source_id: @provider_source_id,
      scope: {
        account_id: @account_id,
        # The pinned DocsGPT extension still names this signed internal scope
        knowledge_index_id: index_id,
        binding_digest: @binding_digest
      }
    )
  end

  def required_status(payload)
    status = payload['status'].to_s
    return status if %w[accepted insufficient_evidence provider_error].include?(status)

    raise ResponseError, "DocsGPT retrieval returned invalid status #{status.inspect}"
  end

  def build_items(payload, knowledge_index_id, manifest, query)
    chunks = payload['chunks']
    raise ResponseError, 'DocsGPT accepted response must contain chunks' unless chunks.is_a?(Array)

    chunks.each_with_index.filter_map do |chunk, index|
      build_evidence(chunk, index + 1, knowledge_index_id, manifest, query)
    end.uniq(&:id).freeze
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def build_evidence(hit, rank, knowledge_index_id, manifest, _query)
    raise ResponseError, "DocsGPT result #{rank} must be an object" unless hit.is_a?(Hash)

    excerpt = required_response_text(hit['text'], rank)
    provider_reference = required_response_string(hit['source'], rank, 'source')
    source = manifest_entry(manifest, provider_reference, rank)
    return unless source.fetch('active')

    authority = source.fetch('authority_class')

    provider_chunk_id = required_response_string(hit['chunk_id'], rank, 'chunk_id')
    score = numeric_score(hit['score'], rank)
    metadata = hit['metadata'].is_a?(Hash) ? hit['metadata'] : {}
    verify_chunk_content_hash!(metadata, excerpt, rank)
    heading_path = metadata['chatring_heading_path'].to_s.presence
    title = source['source_title'].presence || hit['title'].to_s.strip.presence
    ChatRing::Knowledge::Evidence.new(
      id: evidence_id(knowledge_index_id, provider_chunk_id),
      knowledge_index_id: knowledge_index_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      provider_source_id: @provider_source_id,
      provider_chunk_id: provider_chunk_id,
      source_kind: source.fetch('source_kind'),
      source_reference: source.fetch('source_reference'),
      source_title: title,
      public_url: source['public_url'],
      heading_path: heading_path,
      page_locator: source['page_locator'],
      page_headings: source.fetch('headings'),
      cta_candidates: contextual_cta_candidates(source.fetch('cta_candidates'), heading_path),
      locator: heading_path || source['locator'].presence || source.fetch('source_reference'),
      authority_class: authority,
      risk_flags: source.fetch('risk_flags'),
      excerpt: excerpt,
      source_content_hash: source.fetch('content_hash'),
      rank: numeric_rank(hit['rank'] || rank, rank),
      score: score,
      score_kind: required_response_string(hit['score_kind'], rank, 'score_kind'),
      retrieval_strategy: @retrieval_strategy
    )
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

  def build_evidence_set(index_id, query, limit, payload, status, items) # rubocop:disable Metrics/ParameterLists
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: index_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      query: query,
      status: status,
      error_code: status == 'provider_error' ? payload['chatring_error_code'] || 'provider_unavailable' : nil,
      latency_ms: payload['latency_ms']&.to_i,
      retrieval_strategy: @retrieval_strategy,
      retrieval_configuration: retrieval_configuration(limit, payload).freeze,
      items: items.freeze
    )
  end

  def failure_set(index_id, query, limit, status, error_code)
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: index_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      query: query,
      status: status,
      error_code: error_code,
      latency_ms: nil,
      retrieval_strategy: @retrieval_strategy,
      retrieval_configuration: retrieval_configuration(limit, {}).freeze,
      items: [].freeze
    )
  end

  def retrieval_configuration(limit, payload)
    {
      'endpoint' => RETRIEVAL_PATH,
      'limit' => limit,
      'candidate_selection' => @score_threshold.nil? ? 'exact_top_k' : 'legacy_cosine_threshold',
      'score_threshold' => @score_threshold,
      'binding_digest' => @binding_digest,
      'provider' => payload['retrieval']
    }.compact
  end

  def filter_candidates(items)
    return items if @score_threshold.nil?

    items.select { |item| item.score >= @score_threshold }
  end

  def normalize_retrieval_configuration(value)
    config = value.to_h.deep_stringify_keys
    strategy = required_string(config['strategy'], 'retrieval strategy')
    return [strategy, nil] if strategy == RETRIEVAL_STRATEGY && config['candidate_selection'] == 'exact_top_k'
    return [strategy, unit_float(config['score_threshold'], 'score_threshold')] if strategy == LEGACY_RETRIEVAL_STRATEGY

    raise ConfigurationError, "Unsupported retrieval configuration #{strategy.inspect}"
  end

  def manifest_entry(manifest, provider_reference, rank)
    source = manifest[provider_reference]
    return source if source.present?

    raise IntegrityError, "DocsGPT result #{rank} references a source outside the active knowledge index"
  end

  def normalize_manifest(value)
    value.to_h.transform_keys(&:to_s).transform_values do |entry|
      normalize_manifest_entry(entry.to_h.deep_stringify_keys)
    end
  end

  def normalize_manifest_entry(entry) # rubocop:disable Metrics/AbcSize
    {
      'active' => ActiveModel::Type::Boolean.new.cast(entry.fetch('active', true)),
      'content_hash' => required_string(entry['content_hash'], 'source content_hash'),
      'source_kind' => entry['source_kind'].to_s.presence || 'website',
      'source_reference' => required_string(entry['source_reference'], 'source source_reference'),
      'source_title' => entry['source_title'].to_s.presence,
      'public_url' => optional_public_url(entry['public_url']),
      'locator' => entry['locator'].to_s.presence,
      'page_locator' => entry['page_locator'].to_s.presence,
      'authority_class' => required_string(entry['authority_class'], 'source authority_class'),
      'risk_flags' => Array(entry['risk_flags']).map(&:to_s).reject(&:blank?).uniq.freeze,
      'headings' => normalize_headings(entry['headings']),
      'cta_candidates' => normalize_cta_candidates(entry['cta_candidates'])
    }
  end

  def normalize_headings(value)
    Array(value).map do |entry|
      normalized = entry.to_h.deep_stringify_keys
      level = Integer(normalized.fetch('level'))
      raise ConfigurationError, 'source heading level must be between 1 and 6' unless level.between?(1, 6)

      ChatRing::Knowledge::SourceHeading.new(
        level: level,
        text: required_string(normalized['text'], 'heading text'),
        path: required_string(normalized['path'], 'heading path')
      )
    end.freeze
  rescue KeyError, ArgumentError, TypeError
    raise ConfigurationError, 'source headings are invalid'
  end

  def normalize_cta_candidates(value)
    Array(value).map do |entry|
      normalized = entry.to_h.deep_stringify_keys
      ChatRing::Knowledge::CtaCandidate.new(
        label: required_string(normalized['label'], 'CTA label'),
        url: required_http_url(normalized['url'], 'CTA url'),
        heading_path: normalized['heading_path'].to_s.presence,
        external: ActiveModel::Type::Boolean.new.cast(normalized['external'])
      )
    end.freeze
  end

  def contextual_cta_candidates(candidates, heading_path)
    exact = candidates.select { |candidate| candidate.heading_path == heading_path }
    return exact.freeze if exact.any? || heading_path.blank?

    candidates.select { |candidate| candidate.heading_path.blank? }.freeze
  end

  def evidence_id(knowledge_index_id, provider_chunk_id)
    Digest::SHA256.hexdigest([knowledge_index_id, @provider_release, @provider_source_id, provider_chunk_id].join("\0"))
  end

  def numeric_score(value, rank)
    score = Float(value)
    raise ResponseError, "DocsGPT result #{rank} has invalid numeric score" unless score.finite? && score.between?(-1.0, 1.0)

    score
  rescue ArgumentError, TypeError
    raise ResponseError, "DocsGPT result #{rank} is missing numeric score"
  end

  def numeric_rank(value, fallback_rank)
    result = Integer(value)
    raise ResponseError, "DocsGPT result #{fallback_rank} has invalid rank" unless result.positive?

    result
  rescue ArgumentError, TypeError
    raise ResponseError, "DocsGPT result #{fallback_rank} has invalid rank"
  end

  def verify_chunk_content_hash!(metadata, excerpt, rank)
    expected = metadata['chatring_content_hash'].to_s
    raise IntegrityError, "DocsGPT result #{rank} is missing a valid chunk content hash" unless expected.match?(/\A[0-9a-f]{64}\z/)

    actual = Digest::SHA256.hexdigest(excerpt)
    return if actual == expected

    raise IntegrityError, "DocsGPT result #{rank} chunk content hash does not match its excerpt"
  end

  def log_provider_failure(error_code, error)
    Rails.logger.warn(
      "ChatRing DocsGPT retrieval failure code=#{error_code} class=#{error.class.name} message=#{error.message.to_s.truncate(500)}"
    )
  end

  def retrieval_url
    URI.join("#{@base_url}/", RETRIEVAL_PATH.delete_prefix('/')).to_s
  end

  def normalize_base_url(base_url)
    value = required_string(base_url, 'base_url')
    uri = URI.parse(value)
    raise ConfigurationError, 'base_url must use http or https' unless uri.is_a?(URI::HTTP) && uri.host.present?

    value.delete_suffix('/')
  rescue URI::InvalidURIError
    raise ConfigurationError, 'base_url is invalid'
  end

  def required_http_url(value, name)
    url = required_string(value, name)
    unless ChatRing::Knowledge::MarkdownStructure.safe_public_http_url?(url)
      raise ConfigurationError, "#{name} must be a safe public http or https URL"
    end

    url
  end

  def optional_public_url(value)
    return if value.blank?

    required_http_url(value, 'source public_url')
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

  def required_response_text(value, rank)
    result = value.to_s
    raise ResponseError, "DocsGPT result #{rank} is missing text" if result.strip.blank?

    result
  end

  def positive_integer(value, name)
    result = Integer(value)
    raise ConfigurationError, "#{name} must be positive" unless result.positive?

    result
  rescue ArgumentError, TypeError
    raise ConfigurationError, "#{name} must be an integer"
  end

  def unit_float(value, name)
    result = Float(value)
    raise ConfigurationError, "#{name} must be between 0 and 1" unless result.finite? && result.between?(0.0, 1.0)

    result
  rescue ArgumentError, TypeError
    raise ConfigurationError, "#{name} must be numeric"
  end

  def result_limit(value)
    limit = positive_integer(value, 'limit')
    raise ConfigurationError, "limit must be between 1 and #{MAX_RESULTS}" if limit > MAX_RESULTS

    limit
  end

  def sha256_digest(value, name)
    result = required_string(value, name)
    raise ConfigurationError, "#{name} must be a SHA-256 digest" unless result.match?(/\A[0-9a-f]{64}\z/)

    result
  end
end
# rubocop:enable Metrics/ClassLength
