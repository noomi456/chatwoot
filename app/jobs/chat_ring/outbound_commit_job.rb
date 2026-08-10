class ChatRing::OutboundCommitJob < ApplicationJob
  queue_as :high

  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 3

  def perform(turn_id)
    return unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return unless turn&.status_ready_to_commit?

    case turn.decision_type
    when 'reply', 'clarification'
      commit_reply(turn)
    when 'handoff'
      commit_handoff(turn)
    else
      turn.update!(status: :cancelled, failure_code: turn.decision_type)
    end
  end

  private

  def commit_reply(turn)
    outbound_commit = required_outbound_commit(turn, :reply)
    result = Conversations::AgentBotConditionalCommitService.new(
      conversation: turn.conversation,
      agent_bot: turn.expected_agent_bot,
      expected_agent_bot_id: turn.expected_agent_bot_id,
      responding_to_message_id: turn.trigger_message_id,
      idempotency_key: outbound_commit.idempotency_key,
      message: { content: turn.decision_payload.fetch('response_text'), content_type: 'text' }
    ).perform
    turn.update!(status: :committed, failure_code: nil) if result.message.present?
  rescue Conversations::AgentBotConditionalCommitService::PreconditionFailed => e
    finish_rejected_turn(turn, e.code)
  end

  def commit_handoff(turn)
    outbound_commit = required_outbound_commit(turn, :handoff)
    Conversations::AgentBotConditionalHandoffService.new(turn: turn, outbound_commit: outbound_commit).perform
    turn.update!(status: :handed_off, failure_code: nil)
  rescue Conversations::AgentBotConditionalCommitService::PreconditionFailed => e
    finish_rejected_turn(turn, e.code)
  end

  def finish_rejected_turn(turn, failure_code)
    status = %w[newer_customer_message newer_human_reply].include?(failure_code) ? :superseded : :cancelled
    turn.update!(status: status, failure_code: failure_code)
  end

  def required_outbound_commit(turn, outcome_type)
    outbound_commit = turn.outbound_commit || ChatRing::OutboundCommitPreparer.call(turn, turn.decision_type)
    return outbound_commit if outbound_commit&.outcome_type == outcome_type.to_s

    raise ActiveRecord::RecordNotFound, 'Durable ChatRing outbound outcome is missing'
  end
end
