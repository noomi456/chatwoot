class ChatRing::AiTurnRecoveryJob < ApplicationJob
  queue_as :high

  def perform(turn_id)
    turn = ChatRing::AiTurn.find_by(id: turn_id)
    return unless turn
    return ChatRing::AiTurnJob.perform_now(turn.id) unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY

    recover(turn)
  end

  private

  def recover(turn)
    return if terminal?(turn)
    return ChatRing::OutboundCommitDispatcher.call(turn.id) if turn.status_ready_to_commit?
    return ChatRing::AiTurnJob.perform_now(turn.id) if queued_for_inference?(turn) && turn.deadline_at > Time.current
    return if turn.deadline_at > Time.current

    ChatRing::Brain::FailureFinalizer.call(turn.id, 'turn_recovery_deadline')
  end

  def terminal?(turn)
    %w[committed handed_off ineligible superseded failed cancelled].include?(turn.status)
  end

  def queued_for_inference?(turn)
    turn.status_received? || turn.status_eligible?
  end
end
