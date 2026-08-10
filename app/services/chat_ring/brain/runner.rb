require 'digest'

class ChatRing::Brain::Runner # rubocop:disable Metrics/ClassLength
  TRANSIENT_FAILURE_CODES = %w[
    knowledge_provider_failed provider_connection_failed provider_failed provider_rate_limited provider_timeout provider_unavailable
  ].freeze
  RETRIEVAL_TIMEOUT = 10
  OUTCOME_RESERVE = 2
  class DeadlineExpired < StandardError; end

  class RetryableError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  def initialize(turn, provider: nil)
    @turn = turn
    @provider = provider || ChatRing::Brain::RubyLlmProvider.new(turn.assistant_version, deadline_at: turn.deadline_at)
  end

  def call # rubocop:disable Metrics/AbcSize -- explicit typed failure boundary
    return ChatRing::Brain::FailureFinalizer.call(turn.id, 'turn_deadline_expired') if deadline_expired?
    return unless claim_turn!

    execute_claimed_turn
  rescue ChatRing::Brain::RubyLlmProvider::Error => e
    handle_execution_failure(attempt, e.code)
  rescue ChatRing::Brain::Decision::Invalid
    handle_execution_failure(attempt, 'provider_invalid_decision')
  rescue ChatRing::Knowledge::Retriever::Error, ChatRing::Knowledge::DocsGptProvider::ConfigurationError => e
    handle_execution_failure(attempt, "knowledge_configuration_error:#{e.class.name}")
  rescue ArgumentError, KeyError, TypeError => e
    handle_execution_failure(attempt, "brain_configuration_error:#{e.class.name}")
  rescue DeadlineExpired
    fail_attempt!(attempt, 'turn_deadline_expired') if attempt&.status_running?
    ChatRing::Brain::FailureFinalizer.call(turn.id, 'turn_deadline_expired')
  rescue RetryableError => e
    release_for_retry!(e.code)
    raise
  end

  private

  attr_reader :turn, :provider, :attempt

  def execute_claimed_turn
    invocation = ChatRing::Brain::InboundInvocationBuilder.new(turn).build
    persist_invocation_metadata!(invocation)
    return unless recheck_eligibility!

    evidence_set = retrieve_evidence(invocation)
    return handle_retrieval_failure!(evidence_set.error_code || 'knowledge_provider_failed') if evidence_set.status == 'provider_error'

    persist_evidence!(evidence_set)
    return complete_without_evidence!(invocation.digest) if evidence_set.status != 'accepted'
    return unless recheck_eligibility!

    run_inference(invocation, evidence_set)
  end

  def complete_without_evidence!(context_digest)
    decision = ChatRing::Brain::FallbackPolicy.decision(turn.assistant_version, 'insufficient_evidence')
    complete!(decision, context_digest: context_digest)
  end

  def run_inference(invocation, evidence_set)
    ensure_within_deadline!
    result = ChatRing::Brain::Reasoner.new(
      invocation: invocation,
      evidence_set: evidence_set,
      provider: provider
    ).call { |messages| @attempt = start_attempt!(messages) }
    ensure_within_deadline!
    complete_attempt!(attempt, result.provider_result)
    complete!(result.decision, context_digest: invocation.digest)
  end

  def handle_execution_failure(attempt, code)
    fail_attempt!(attempt, code) if attempt
    return ChatRing::Brain::FailureFinalizer.call(turn.id, code) unless retryable_failure?(code) && !deadline_expired?

    release_for_retry!(code)
    raise RetryableError, code
  end

  def handle_retrieval_failure!(code)
    return ChatRing::Brain::FailureFinalizer.call(turn.id, code) unless retryable_failure?(code)

    raise RetryableError, code
  end

  def retryable_failure?(code)
    TRANSIENT_FAILURE_CODES.include?(code)
  end

  def claim_turn!
    claimed = false
    turn.with_lock do
      turn.reload
      next unless turn.status_received? || turn.status_eligible?

      eligibility = ChatRing::Brain::Eligibility.check(turn)
      unless eligibility.eligible
        mark_ineligible!(eligibility.reason)
        next
      end

      pinned_index_id = ChatRing::Knowledge::Retriever.active_index_id(inbox: turn.conversation.inbox)
      turn.update!(status: :running, started_at: turn.started_at || Time.current, knowledge_index_id: pinned_index_id)
      claimed = true
    end
    claimed
  end

  def mark_ineligible!(reason)
    status = %w[newer_customer_message newer_human_reply].include?(reason) ? :superseded : :ineligible
    turn.update!(status: status, decision_type: reason, completed_at: Time.current)
  end

  def retrieve_evidence(invocation)
    ensure_within_deadline!
    ChatRing::Knowledge::Retriever.retrieve(
      inbox: turn.conversation.inbox,
      query: invocation.query,
      knowledge_scope: turn.assistant_version.knowledge_scope,
      knowledge_index_id: turn.knowledge_index_id,
      timeout_seconds: remaining_timeout(RETRIEVAL_TIMEOUT)
    )
  end

  def remaining_timeout(maximum)
    remaining = (turn.deadline_at - Time.current - OUTCOME_RESERVE).floor
    raise DeadlineExpired unless remaining.positive?

    [remaining, maximum].min
  end

  def persist_invocation_metadata!(invocation)
    turn.with_lock do
      turn.reload
      turn.update!(context_metadata: invocation.audit_metadata) if turn.status_running?
    end
  end

  def ensure_within_deadline!
    raise DeadlineExpired if deadline_expired?
  end

  def recheck_eligibility!
    eligible = false
    turn.with_lock do
      turn.reload
      next unless turn.status_running?

      eligibility = ChatRing::Brain::Eligibility.check(turn)
      if eligibility.eligible
        eligible = true
      else
        mark_ineligible!(eligibility.reason)
      end
    end
    eligible
  end

  def deadline_expired?
    turn.deadline_at.blank? || turn.deadline_at <= Time.current
  end

  def persist_evidence!(evidence_set)
    turn.with_lock do
      turn.evidence.delete_all
      evidence_set.items.each_with_index do |item, position|
        turn.evidence.create!(evidence_attributes(item, position))
      end
    end
  end

  def evidence_attributes(item, position)
    {
      position: position,
      evidence_id: item.id,
      knowledge_index_id: item.knowledge_index_id,
      provider_source_id: item.provider_source_id,
      provider_chunk_id: item.provider_chunk_id,
      source_kind: item.source_kind,
      source_reference: item.source_reference,
      source_title: item.source_title,
      public_url: item.public_url,
      heading_path: item.heading_path,
      excerpt: item.excerpt,
      source_content_hash: item.source_content_hash,
      rank: item.rank,
      score: item.score,
      metadata: evidence_metadata(item)
    }
  end

  def evidence_metadata(item)
    {
      'page_locator' => item.page_locator,
      'page_headings' => item.page_headings,
      'cta_candidates' => item.cta_candidates,
      'authority_class' => item.authority_class,
      'risk_flags' => item.risk_flags,
      'retrieval_strategy' => item.retrieval_strategy
    }.compact
  end

  def start_attempt!(messages)
    turn.with_lock do
      turn.attempts.create!(
        attempt_number: turn.attempts.maximum(:attempt_number).to_i + 1,
        provider: turn.assistant_version.llm_provider,
        model: turn.assistant_version.llm_model,
        status: :running,
        request_digest: Digest::SHA256.hexdigest(messages.to_json),
        started_at: Time.current
      )
    end
  end

  def complete_attempt!(attempt, result)
    attempt.update!(
      status: :succeeded,
      response_digest: result.response_digest,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
      completed_at: Time.current,
      failure_code: nil
    )
  end

  def fail_attempt!(attempt, code)
    attempt.update!(status: :failed, failure_code: code, completed_at: Time.current)
  end

  def release_for_retry!(code)
    turn.with_lock do
      turn.reload
      next unless turn.status_running?

      if code == 'turn_deadline_expired' || turn.deadline_at.blank? || turn.deadline_at <= Time.current
        turn.update!(status: :ineligible, decision_type: 'turn_deadline_expired', failure_code: code, completed_at: Time.current)
      else
        turn.update!(status: :received, failure_code: code)
      end
    end
  end

  def complete!(decision, context_digest: nil)
    turn.with_lock do
      turn.reload
      next unless turn.status_running?

      eligibility = ChatRing::Brain::Eligibility.check(turn)
      unless eligibility.eligible
        mark_ineligible!(eligibility.reason)
        next
      end

      effectful = ChatRing::OutboundCommitPreparer::EFFECTFUL_DECISIONS.key?(decision.decision_type)
      ChatRing::OutboundCommitPreparer.call(turn, decision.decision_type) if effectful
      turn.update!(
        status: effectful ? :ready_to_commit : :cancelled,
        decision_type: decision.decision_type,
        decision_payload: decision.to_h,
        context_digest: context_digest,
        failure_code: nil,
        completed_at: Time.current
      )
    end
  end
end
