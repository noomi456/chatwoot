module ChatRing::AutomationRuleListener
  def message_created(event)
    message = event.data[:message]
    return super unless message && ChatRing::NativeHandling::CompletionRecorder.candidate?(message)

    result = nil
    effects = ChatRing::NativeHandling::AutomationEffectCollector.capture { result = super }
    record_automation_completion(message, effects)
    result
  end

  private

  def record_automation_completion(message, effects)
    ChatRing::NativeHandling::CompletionRecorder.record_automation(message: message, effects: effects)
  rescue StandardError => e
    Rails.logger.error("[ChatRing] automation completion observation failed message_id=#{message.id} error=#{e.class.name}")
  end
end
