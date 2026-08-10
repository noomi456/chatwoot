module ChatRing::MessageTemplates::HookExecutionService
  def perform
    template_ids_before = conversation_template_ids
    result = super
    record_template_completion(template_ids_before)
    result
  end

  private

  def record_template_completion(template_ids_before)
    ChatRing::NativeHandling::CompletionRecorder.record_template(
      message: message,
      template_ids_before: template_ids_before
    )
  rescue StandardError => e
    Rails.logger.error("[ChatRing] template completion observation failed message_id=#{message.id} error=#{e.class.name}")
  end

  def conversation_template_ids
    message.conversation.messages.template.reorder(:id).pluck(:id)
  end
end
