class ChatRing::AiTurnRecoverySweepJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    terminalize_gate_closed_playbooks unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    ChatRing::AiTurn.recovery_due.order(:updated_at, :id).limit(BATCH_SIZE).each do |turn|
      safely_enqueue(turn)
    end
  end

  private

  def terminalize_gate_closed_playbooks
    ChatRing::InboxPlaybookExecution.controlling.order(:updated_at, :id).limit(BATCH_SIZE).each do |execution|
      terminalize_gate_closed_playbook(execution)
    rescue StandardError => e
      Rails.logger.warn("ChatRing Playbook gate cleanup failed execution_id=#{execution.id} class=#{e.class.name}")
    end
  end

  def terminalize_gate_closed_playbook(source_execution)
    Account.transaction do
      conversation = source_execution.conversation
      Account.lock.find(conversation.account_id)
      Inbox.lock.find(conversation.inbox_id)
      Conversation.lock.find(conversation.id)
      execution = ChatRing::InboxPlaybookExecution.controlling.lock.find_by(id: source_execution.id)
      ChatRing::Playbooks::ExecutionFinalizer.apply_execution_locked!(
        execution: execution,
        status: :superseded,
        action: 'public_response_gate_closed',
        failure_code: 'public_response_gate_closed'
      )
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def safely_enqueue(turn)
    job = ChatRing::AiTurnRecoveryJob.perform_later(turn.id)
    return turn.update!(updated_at: Time.current) if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?

    Rails.logger.warn("ChatRing AI recovery enqueue rejected turn_id=#{turn.id}")
  rescue StandardError => e
    Rails.logger.warn("ChatRing AI recovery enqueue failed turn_id=#{turn.id} class=#{e.class.name}")
  end
end
