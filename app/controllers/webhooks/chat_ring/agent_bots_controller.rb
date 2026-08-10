class Webhooks::ChatRing::AgentBotsController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ChatRing::WebhookIngress::SignatureVerifier::VerificationError, with: :render_unauthorized
  rescue_from ChatRing::WebhookIngress::Receiver::DeliveryCollision, with: :render_conflict
  rescue_from ChatRing::WebhookIngress::Receiver::InvalidPayload,
              ChatRing::WebhookIngress::Receiver::ScopeMismatch,
              with: :render_unprocessable_entity

  def events
    return head :not_found unless external_public_runtime_enabled?

    result = receive_delivery
    return head :ok unless result.delivery.received?

    enqueue_delivery(result.delivery)
  end

  private

  def external_public_runtime_enabled?
    ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY && ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
  end

  def receive_delivery
    connection = ChatRing::AssistantAgentBotConnection.find_by!(webhook_key: params[:webhook_key])
    ChatRing::WebhookIngress::Receiver.new(
      connection: connection,
      raw_body: request.raw_post,
      headers: request.headers
    ).call
  end

  def enqueue_delivery(delivery)
    job = ChatRing::WebhookDeliveryJob.perform_later(delivery.id)
    return head :ok if job.present? && job.successfully_enqueued?

    Rails.logger.error("[ChatRing::WebhookIngress] enqueue failed delivery_id=#{delivery.delivery_id}")
    head :internal_server_error
  end

  def render_not_found(_error)
    head :not_found
  end

  def render_unauthorized(error)
    Rails.logger.warn("[ChatRing::WebhookIngress] signature rejected webhook_key=#{params[:webhook_key]} error=#{error.message}")
    head :unauthorized
  end

  def render_conflict(error)
    Rails.logger.error("[ChatRing::WebhookIngress] delivery collision error=#{error.message}")
    head :conflict
  end

  def render_unprocessable_entity(error)
    Rails.logger.warn("[ChatRing::WebhookIngress] delivery rejected webhook_key=#{params[:webhook_key]} error=#{error.message}")
    head :unprocessable_entity
  end
end
