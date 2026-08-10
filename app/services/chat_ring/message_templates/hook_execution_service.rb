module ChatRing::MessageTemplates::HookExecutionService
  def perform
    template_ids_before = conversation_template_ids
    super
    ChatRing::InternalTurnScheduler.new(
      message: message,
      template_ids_before: template_ids_before
    ).call
  end

  private

  def conversation_template_ids
    message.conversation.messages.template.reorder(:id).pluck(:id)
  end
end
