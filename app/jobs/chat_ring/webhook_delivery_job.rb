class ChatRing::WebhookDeliveryJob < ApplicationJob
  queue_as :high

  def perform(delivery_id)
    delivery = ChatRing::WebhookDelivery.find(delivery_id)
    return disable_delivery!(delivery) unless external_runtime_open?

    turn = delivery.with_lock do
      next unless delivery.received?

      process_delivery!(delivery)
    end
    return if turn.blank?

    enqueue_turn!(turn)
    delivery.with_lock do
      delivery.update!(processing_status: :processed, error_code: nil) if delivery.received?
    end
  end

  private

  def external_runtime_open?
    ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY && ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
  end

  def disable_delivery!(delivery)
    delivery.with_lock { ignore!(delivery, 'external_runtime_disabled') if delivery.received? }
  end

  def process_delivery!(delivery)
    return ignore!(delivery, 'unsupported_event') unless delivery.event_type == 'message_created'

    message = authoritative_message(delivery)
    return ignore!(delivery, 'message_not_found') if message.blank?
    return ignore!(delivery, 'not_customer_public_message') unless customer_public_message?(message)

    binding = delivery.assistant_agent_bot_connection.inbox_bindings
                      .where(chatwoot_inbox_id: message.inbox_id)
                      .order(binding_version: :desc)
                      .first
    return ignore!(delivery, 'binding_not_found') if binding.blank?

    assistant_version = binding.assistant.current_version
    return ignore!(delivery, 'assistant_version_not_found') if assistant_version.blank?

    dispatch_turn!(delivery, message, binding, assistant_version)
  end

  def dispatch_turn!(delivery, message, binding, assistant_version)
    turn = create_turn!(delivery, message, binding, assistant_version)
    return turn if turn.status_received?
    return ignore!(delivery, turn.decision_type) if turn.status_ineligible? || turn.status_superseded?

    delivery.update!(processing_status: :processed, error_code: nil)
    nil
  end

  def authoritative_message(delivery)
    Message.find_by(
      id: delivery.payload_message_id,
      account_id: delivery.payload_account_id,
      inbox_id: delivery.payload_inbox_id
    )
  end

  def customer_public_message?(message)
    message.incoming? && !message.private? && message.sender_type == 'Contact'
  end

  def create_turn!(delivery, message, binding, assistant_version)
    assistant = binding.assistant
    eligible, reason = base_eligibility(delivery, message, binding)
    ChatRing::AiTurn.find_or_create_by!(
      workspace: delivery.workspace,
      conversation: message.conversation,
      trigger_message: message
    ) do |turn|
      turn.inbox_assistant_binding = binding
      turn.binding_version = binding.binding_version
      turn.assistant = assistant
      turn.assistant_version = assistant_version
      turn.expected_agent_bot = delivery.assistant_agent_bot_connection.agent_bot
      turn.runtime_mode = :external
      turn.deadline_at = Time.current + ChatRing::AiTurn::DEFAULT_DEADLINE
      turn.status = eligible ? :received : :ineligible
      turn.decision_type = reason unless eligible
      turn.completed_at = Time.current unless eligible
    end
  end

  def enqueue_turn!(turn)
    job = ChatRing::AiTurnJob.perform_later(turn.id)
    raise 'ChatRing AI turn could not be queued' unless job_enqueued?(job)
  end

  def job_enqueued?(job)
    return false if job.blank?

    job.successfully_enqueued?
  end

  def base_eligibility(delivery, message, binding)
    reason = eligibility_failure(delivery, message, binding)
    [reason.nil?, reason]
  end

  def eligibility_failure(delivery, message, binding)
    configuration_failure(delivery, binding) || ownership_failure(delivery, message)
  end

  def configuration_failure(delivery, binding)
    connection = delivery.assistant_agent_bot_connection
    return 'workspace_inactive' if delivery.workspace.status != 'active'
    return 'binding_inactive' unless binding.active?
    return 'assistant_inactive' unless binding.assistant.active?
    return 'connection_inactive' unless connection.active?
    return 'account_mismatch' unless connection.agent_bot.account_id == delivery.workspace.chatwoot_account_id
  end

  def ownership_failure(delivery, message)
    connection = delivery.assistant_agent_bot_connection
    return 'inbox_connection_inactive' unless connected_to_inbox?(connection, message.inbox_id)
    return 'conversation_not_pending' unless message.conversation.pending?
    return 'unexpected_agent_bot' unless message.conversation.assignee_agent_bot_id == connection.agent_bot_id
  end

  def connected_to_inbox?(connection, inbox_id)
    AgentBotInbox.active.exists?(inbox_id: inbox_id, agent_bot_id: connection.agent_bot_id)
  end

  def ignore!(delivery, error_code)
    delivery.update!(processing_status: :ignored, error_code: error_code)
    nil
  end
end
