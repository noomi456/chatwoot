require 'digest'

class ChatRing::Knowledge::EvaluationService
  MIN_ACCEPTED_CASES = 5
  MIN_NEGATIVE_CASES = 5
  REQUIRED_CATEGORIES = %w[positive ambiguous unsupported adversarial compliance].freeze
  EXPECTATIONS = %w[accepted insufficient_evidence].freeze

  class Error < StandardError; end

  def self.evaluate!(version, cases:, provider: nil)
    new(version, cases: cases, provider: provider).evaluate!
  end

  def initialize(version, cases:, provider: nil)
    @version = version
    @cases = normalize_cases(cases)
    @provider = provider
  end

  def evaluate!
    raise Error, "Knowledge version #{@version.id} is not ready for evaluation" unless %w[ready published retired].include?(@version.status)

    validate_suite!
    results = @cases.map { |test_case| evaluate_case(test_case) }
    report = {
      'binding_digest' => @version.evaluation_binding_digest,
      'suite_digest' => Digest::SHA256.hexdigest(@cases.to_json),
      'case_count' => results.length,
      'passed_count' => results.count { |result| result['passed'] },
      'cases' => results
    }
    passed = results.all? { |result| result['passed'] }
    @version.update!(
      evaluation_status: passed ? 'passed' : 'failed',
      evaluation_report: report,
      evaluated_at: Time.current
    )
    raise Error, "Knowledge version #{@version.id} failed #{results.length - report['passed_count']} evaluation case(s)" unless passed

    report
  end

  private

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def normalize_cases(cases)
    raise Error, 'Evaluation cases must be an array' unless cases.is_a?(Array)

    cases.map.with_index do |entry, index|
      raise Error, "Evaluation case #{index + 1} must be an object" unless entry.is_a?(Hash)

      test_case = entry.deep_stringify_keys
      query = test_case['query'].to_s.squish
      category = test_case['category'].to_s
      expectation = test_case['expectation'].to_s
      raise Error, "Evaluation case #{index + 1} is missing a query" if query.blank?
      raise Error, "Evaluation case #{index + 1} has an invalid category" unless REQUIRED_CATEGORIES.include?(category)
      raise Error, "Evaluation case #{index + 1} has an invalid expectation" unless EXPECTATIONS.include?(expectation)

      {
        'query' => query,
        'category' => category,
        'expectation' => expectation,
        'expected_text' => test_case['expected_text'].to_s.squish.presence,
        'expected_urls' => Array(test_case['expected_urls']).map do |url|
          ChatRing::Knowledge::FirecrawlClient.canonical_url(url)
        end.uniq.sort
      }
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

  def validate_suite! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    accepted = @cases.count { |test_case| test_case['expectation'] == 'accepted' }
    negative = @cases.count { |test_case| test_case['expectation'] == 'insufficient_evidence' }
    categories = @cases.pluck('category').uniq
    missing_categories = REQUIRED_CATEGORIES - categories
    raise Error, "Evaluation suite requires at least #{MIN_ACCEPTED_CASES} accepted cases" if accepted < MIN_ACCEPTED_CASES
    raise Error, "Evaluation suite requires at least #{MIN_NEGATIVE_CASES} negative cases" if negative < MIN_NEGATIVE_CASES
    raise Error, "Evaluation suite is missing categories: #{missing_categories.join(', ')}" if missing_categories.any?
    if @cases.any? { |test_case| test_case['expectation'] == 'accepted' && test_case['expected_urls'].empty? }
      raise Error, 'Every accepted evaluation case must identify at least one expected source URL'
    end
    raise Error, 'Every accepted evaluation case must identify expected passage text' if
      @cases.any? { |test_case| test_case['expectation'] == 'accepted' && test_case['expected_text'].blank? }
  end

  def evaluate_case(test_case) # rubocop:disable Metrics/MethodLength
    evidence_set = provider.retrieve(
      query: test_case.fetch('query'),
      knowledge_version_id: @version.id.to_s,
      source_manifest: ChatRing::Knowledge::Retriever.source_manifest(@version),
      limit: 5
    )
    actual_urls = evidence_set.items.map(&:source_reference).uniq.sort
    passed = expected_status?(test_case, evidence_set) &&
             expected_source?(test_case, actual_urls) &&
             expected_text?(test_case, evidence_set)
    test_case.merge(
      'actual_status' => evidence_set.status,
      'actual_urls' => actual_urls,
      'evidence_ids' => evidence_set.items.map(&:id),
      'passed' => passed
    )
  rescue StandardError => e
    test_case.merge(
      'actual_status' => 'provider_error',
      'error_class' => e.class.name,
      'passed' => false
    )
  end

  def expected_status?(test_case, evidence_set)
    evidence_set.status == test_case.fetch('expectation') &&
      (evidence_set.status != 'insufficient_evidence' || evidence_set.items.empty?)
  end

  def expected_source?(test_case, actual_urls)
    return true if test_case['expectation'] == 'insufficient_evidence'

    test_case.fetch('expected_urls').intersect?(actual_urls)
  end

  def expected_text?(test_case, evidence_set)
    return true if test_case['expectation'] == 'insufficient_evidence'

    needle = test_case.fetch('expected_text').downcase
    evidence_set.items.any? { |item| item.excerpt.to_s.downcase.include?(needle) }
  end

  def provider
    @provider ||= ChatRing::Knowledge::DocsGptProvider.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      provider_release: @version.provider_release,
      provider_source_id: provider_source_id,
      account_id: @version.account_id,
      binding_digest: @version.evaluation_binding_digest,
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET'),
      score_threshold: @version.config_snapshot.dig('retrieval', 'score_threshold') || ENV.fetch('DOCSGPT_SCORE_THRESHOLD')
    )
  end

  def provider_source_id
    source_ids = @version.documents.pluck(:provider_source_id).compact_blank.uniq
    raise Error, 'Evaluation requires exactly one DocsGPT source' unless source_ids.one?

    source_ids.first
  end
end
