require 'digest'
require 'httparty'
require 'uri'

# rubocop:disable Metrics/ClassLength
class ChatRing::Knowledge::DocsGptProvider
  PROVIDER = 'docs_gpt'.freeze
  RETRIEVAL_STRATEGY = 'docs_gpt_dispatcher_classic_cosine'.freeze
  RETRIEVAL_PATH = '/api/internal/chatring/retrieve'.freeze
  MAX_RESULTS = 20
  MAX_QUERY_LENGTH = 2000
  HIGH_RISK_PATTERN = /\b(hipaa|soc\s*2|iso\s*27001|data\s+residen(?:cy|t)|end[- ]to[- ]end encrypt|gdpr (?:compliant|compliance))\b/i
  HIGH_RISK_AUTHORITIES = %w[approved_compliance].freeze
  LEGAL_POLICY_PATTERN = /\b(refunds?|returns?|cancell?ation|money[- ]back|privacy policy|cookie policy|data (?:collection|retention|deletion))\b/i
  LEGAL_POLICY_AUTHORITIES = %w[approved_legal_policy].freeze

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end
  class ResponseError < Error; end

  # rubocop:disable Metrics/ParameterLists
  def initialize(base_url:, provider_release:, provider_source_id:, account_id:, binding_digest:, internal_key:,
                 service_secret:, score_threshold:, timeout_seconds: 10)
    @base_url = normalize_base_url(base_url)
    @provider_release = required_string(provider_release, 'provider_release')
    @provider_source_id = required_string(provider_source_id, 'provider_source_id')
    @account_id = required_string(account_id, 'account_id')
    @binding_digest = sha256_digest(binding_digest, 'binding_digest')
    @score_threshold = unit_float(score_threshold, 'score_threshold')
    @timeout_seconds = positive_integer(timeout_seconds, 'timeout_seconds')
    @auth = ChatRing::Knowledge::DocsGptAuth.new(
      internal_key: internal_key,
      service_secret: service_secret
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def retrieve(query:, knowledge_version_id:, source_manifest:, limit: 5) # rubocop:disable Metrics/MethodLength
    resolved_query = required_string(query, 'query')
    raise ConfigurationError, "query must not exceed #{MAX_QUERY_LENGTH} characters" if resolved_query.length > MAX_QUERY_LENGTH

    version_id = required_string(knowledge_version_id, 'knowledge_version_id')
    result_limit = result_limit(limit)
    manifest = normalize_manifest(source_manifest)
    body = {
      query: resolved_query,
      source_id: @provider_source_id,
      limit: result_limit,
      score_threshold: @score_threshold
    }.to_json
    payload = fetch_payload(body, version_id)
    status = required_status(payload)
    items = status == 'accepted' ? build_items(payload, version_id, manifest, resolved_query) : []
    status = 'insufficient_evidence' if status == 'accepted' && items.empty?
    build_evidence_set(version_id, resolved_query, result_limit, payload, status, items)
  rescue Timeout::Error
    failure_set(version_id, resolved_query, result_limit, 'timeout', 'provider_timeout')
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH => e
    failure_set(version_id, resolved_query, result_limit, 'provider_error', e.class.name)
  end

  private

  def fetch_payload(body, version_id)
    headers = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json'
    }.merge(auth_headers(body, version_id))
    response = HTTParty.post(retrieval_url, headers: headers, body: body, timeout: @timeout_seconds)
    parsed = response.parsed_response
    raise ResponseError, "DocsGPT retrieval response is invalid (HTTP #{response.code})" unless parsed.is_a?(Hash)

    return parsed if response.success? || response.code == 503

    raise RequestError, "DocsGPT retrieval failed with HTTP #{response.code}"
  end

  def auth_headers(body, version_id)
    @auth.internal_headers(
      body: body,
      operation: 'retrieve',
      source_id: @provider_source_id,
      scope: {
        account_id: @account_id,
        knowledge_version_id: version_id,
        binding_digest: @binding_digest
      }
    )
  end

  def required_status(payload)
    status = payload['status'].to_s
    return status if %w[accepted insufficient_evidence provider_error].include?(status)

    raise ResponseError, "DocsGPT retrieval returned invalid status #{status.inspect}"
  end

  def build_items(payload, knowledge_version_id, manifest, query)
    chunks = payload['chunks']
    raise ResponseError, 'DocsGPT accepted response must contain chunks' unless chunks.is_a?(Array)

    chunks.each_with_index.filter_map do |chunk, index|
      build_evidence(chunk, index + 1, knowledge_version_id, manifest, query)
    end.uniq(&:id).freeze
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def build_evidence(hit, rank, knowledge_version_id, manifest, query)
    raise ResponseError, "DocsGPT result #{rank} must be an object" unless hit.is_a?(Hash)

    excerpt = required_response_string(hit['text'], rank, 'text')
    provider_reference = required_response_string(hit['source'], rank, 'source')
    source = manifest_entry(manifest, provider_reference, rank)
    authority = source.fetch('authority_class')
    return unless authority_allowed?(query, authority)

    provider_chunk_id = required_response_string(hit['chunk_id'], rank, 'chunk_id')
    score = numeric_score(hit['score'], rank)
    raise ResponseError, "DocsGPT result #{rank} is below the provider threshold" if score < @score_threshold

    metadata = hit['metadata'].is_a?(Hash) ? hit['metadata'] : {}
    verify_chunk_content_hash!(metadata, excerpt, rank)
    heading_path = metadata['chatring_heading_path'].to_s.presence
    title = source['source_title'].presence || hit['title'].to_s.strip.presence
    ChatRing::Knowledge::Evidence.new(
      id: evidence_id(knowledge_version_id, provider_chunk_id),
      knowledge_version_id: knowledge_version_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      provider_source_id: @provider_source_id,
      provider_chunk_id: provider_chunk_id,
      source_reference: source.fetch('source_reference'),
      source_title: title,
      heading_path: heading_path,
      page_headings: source.fetch('headings'),
      cta_candidates: contextual_cta_candidates(source.fetch('cta_candidates'), heading_path),
      locator: heading_path || source['locator'].presence || source.fetch('source_reference'),
      authority_class: authority,
      excerpt: excerpt,
      source_content_hash: source.fetch('content_hash'),
      rank: Integer(hit['rank'] || rank),
      score: score,
      score_kind: required_response_string(hit['score_kind'], rank, 'score_kind'),
      retrieval_strategy: RETRIEVAL_STRATEGY
    )
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def build_evidence_set(version_id, query, limit, payload, status, items) # rubocop:disable Metrics/ParameterLists
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_version_id: version_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      query: query,
      status: status,
      error_code: status == 'provider_error' ? 'provider_error' : nil,
      latency_ms: payload['latency_ms']&.to_i,
      retrieval_strategy: RETRIEVAL_STRATEGY,
      retrieval_configuration: retrieval_configuration(limit, payload).freeze,
      items: items.freeze
    )
  end

  def failure_set(version_id, query, limit, status, error_code)
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_version_id: version_id,
      provider: PROVIDER,
      provider_release: @provider_release,
      query: query,
      status: status,
      error_code: error_code,
      latency_ms: nil,
      retrieval_strategy: RETRIEVAL_STRATEGY,
      retrieval_configuration: retrieval_configuration(limit, {}).freeze,
      items: [].freeze
    )
  end

  def retrieval_configuration(limit, payload)
    {
      'endpoint' => RETRIEVAL_PATH,
      'limit' => limit,
      'score_threshold' => @score_threshold,
      'binding_digest' => @binding_digest,
      'provider' => payload['retrieval']
    }.compact
  end

  def manifest_entry(manifest, provider_reference, rank)
    source = manifest[provider_reference]
    return source if source.present?

    raise ResponseError, "DocsGPT result #{rank} references a source outside the knowledge-version manifest"
  end

  def normalize_manifest(value)
    value.to_h.transform_keys(&:to_s).transform_values do |entry|
      normalized = entry.to_h.deep_stringify_keys
      {
        'content_hash' => required_string(normalized['content_hash'], 'source content_hash'),
        'source_reference' => required_string(normalized['source_reference'], 'source source_reference'),
        'source_title' => normalized['source_title'].to_s.presence,
        'locator' => normalized['locator'].to_s.presence,
        'authority_class' => required_string(normalized['authority_class'], 'source authority_class'),
        'headings' => normalize_headings(normalized['headings']),
        'cta_candidates' => normalize_cta_candidates(normalized['cta_candidates'])
      }
    end
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
    candidates.sort_by { |candidate| candidate.heading_path == heading_path ? 0 : 1 }.freeze
  end

  def evidence_id(knowledge_version_id, provider_chunk_id)
    Digest::SHA256.hexdigest([knowledge_version_id, @provider_release, @provider_source_id, provider_chunk_id].join("\0"))
  end

  def high_risk_query?(query)
    HIGH_RISK_PATTERN.match?(query)
  end

  def authority_allowed?(query, authority)
    return false if high_risk_query?(query) && HIGH_RISK_AUTHORITIES.exclude?(authority)
    return false if LEGAL_POLICY_PATTERN.match?(query) && LEGAL_POLICY_AUTHORITIES.exclude?(authority)

    true
  end

  def numeric_score(value, rank)
    score = Float(value)
    raise ResponseError, "DocsGPT result #{rank} has invalid numeric score" unless score.finite? && score.between?(-1.0, 1.0)

    score
  rescue ArgumentError, TypeError
    raise ResponseError, "DocsGPT result #{rank} is missing numeric score"
  end

  def verify_chunk_content_hash!(metadata, excerpt, rank)
    expected = metadata['chatring_content_hash'].to_s
    raise ResponseError, "DocsGPT result #{rank} is missing a valid chunk content hash" unless expected.match?(/\A[0-9a-f]{64}\z/)

    actual = Digest::SHA256.hexdigest(excerpt)
    return if actual == expected

    raise ResponseError, "DocsGPT result #{rank} chunk content hash does not match its excerpt"
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
    uri = URI.parse(url)
    raise ConfigurationError, "#{name} must use http or https" unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?

    url
  rescue URI::InvalidURIError
    raise ConfigurationError, "#{name} is invalid"
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

  def unit_float(value, name)
    result = Float(value)
    raise ConfigurationError, "#{name} must be between 0 and 1" unless result.finite? && result.between?(0.0, 1.0)

    result
  rescue ArgumentError, TypeError
    raise ConfigurationError, "#{name} must be numeric"
  end

  def sha256_digest(value, name)
    result = required_string(value, name)
    raise ConfigurationError, "#{name} must be a SHA-256 digest" unless result.match?(/\A[0-9a-f]{64}\z/)

    result
  end
end
# rubocop:enable Metrics/ClassLength
