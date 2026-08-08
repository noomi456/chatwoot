require 'digest'

class ChatRing::Brain::Runner
  class RetryableError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  def initialize(turn, provider: nil)
    @turn = turn
    @provider = provider || ChatRing::Brain::RubyLlmProvider.new(turn.assistant_version)
  end

  def call
    return unless claim_turn!

    execute_claimed_turn
  rescue ChatRing::Brain::RubyLlmProvider::Error => e
    handle_provider_failure(attempt, e.code)
  rescue ChatRing::Brain::Decision::Invalid
    handle_provider_failure(attempt, 'provider_invalid_decision')
  rescue RetryableError => e
    release_for_retry!(e.code)
    raise
  end

  private

  attr_reader :turn, :provider, :attempt

  def execute_claimed_turn
    context = ChatRing::Brain::ContextBuilder.new(turn).build
    context_digest = Digest::SHA256.hexdigest(context.to_json)
    evidence_set = retrieve_evidence
    raise RetryableError, evidence_set.error_code || 'knowledge_provider_failed' if evidence_set.status == 'provider_error'

    persist_evidence!(evidence_set)
    return complete_without_evidence!(context_digest) if evidence_set.status != 'accepted'

    run_inference(context, evidence_set)
  end

  def complete_without_evidence!(context_digest)
    decision = ChatRing::Brain::FallbackPolicy.decision(turn.assistant_version, 'insufficient_evidence')
    complete!(decision, context_digest: context_digest)
  end

  def run_inference(context, evidence_set)
    messages = ChatRing::Brain::PromptBuilder.messages(context: context, evidence_set: evidence_set)
    @attempt = start_attempt!(messages)
    result = provider.call(messages: messages)
    decision = ChatRing::Brain::Decision.from_payload(
      result.payload,
      allowed_evidence_ids: evidence_set.items.map(&:id),
      evidence_status: evidence_set.status
    )
    complete_attempt!(attempt, result)
    complete!(decision, context_digest: Digest::SHA256.hexdigest(messages.to_json))
  end

  def handle_provider_failure(attempt, code)
    fail_attempt!(attempt, code) if attempt
    release_for_retry!(code)
    raise RetryableError, code
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

  def retrieve_evidence
    ChatRing::Knowledge::Retriever.retrieve(
      inbox: turn.conversation.inbox,
      query: turn.trigger_message.content_for_llm.to_s,
      knowledge_scope: turn.assistant_version.knowledge_scope,
      knowledge_index_id: turn.knowledge_index_id
    )
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
      turn.update!(status: :received, failure_code: code) if turn.status_running?
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

      turn.update!(
        status: :ready_to_commit,
        decision_type: decision.decision_type,
        decision_payload: decision.to_h,
        context_digest: context_digest,
        failure_code: nil,
        completed_at: Time.current
      )
    end
  end
end
