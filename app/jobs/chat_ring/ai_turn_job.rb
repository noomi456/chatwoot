class ChatRing::AiTurnJob < ApplicationJob
  class CommitEnqueueError < StandardError; end

  queue_as :high

  retry_on ChatRing::Brain::Runner::RetryableError,
           wait: :polynomially_longer,
           attempts: 3 do |job, error|
    ChatRing::Brain::FailureFinalizer.call(job.arguments.first, error.code)
  end
  retry_on CommitEnqueueError, wait: :polynomially_longer, attempts: 3

  def perform(turn_id)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return unless turn
    return cancel_gate_closed_turn(turn) unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    ChatRing::Brain::Runner.new(turn).call
    enqueue_commit!(turn.reload)
  end

  private

  def cancel_gate_closed_turn(turn)
    turn.with_lock do
      turn.reload
      next unless ChatRing::AiTurn::NONTERMINAL_STATUSES.include?(turn.status)

      committed_outcome = turn.outbound_commit
      if committed_outcome&.status_committed?
        turn.update!(
          status: committed_outcome.outcome_type_handoff? ? :handed_off : :committed,
          failure_code: nil,
          completed_at: turn.completed_at || committed_outcome.committed_at || Time.current
        )
        next
      end

      turn.update!(
        status: :cancelled,
        failure_code: 'public_response_gate_closed',
        completed_at: Time.current
      )
    end
  end

  def enqueue_commit!(turn)
    return unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    return unless turn.status_ready_to_commit?

    job = ChatRing::OutboundCommitJob.perform_later(turn.id)
    raise CommitEnqueueError unless job&.successfully_enqueued?
  end
end
