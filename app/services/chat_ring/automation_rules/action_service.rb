module ChatRing::AutomationRules::ActionService
  def perform
    return super unless ChatRing::NativeHandling::AutomationEffectCollector.active?

    before = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation)
    result = super
    after = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation)
    ChatRing::NativeHandling::AutomationEffectCollector.record(rule: @rule, before: before, after: after)
    result
  end

  private

  def send_attachment(blob_ids)
    record_automation_message(super)
  end

  def send_message(message)
    record_automation_message(super)
  end

  def add_private_note(message)
    record_automation_message(super)
  end

  def record_automation_message(message)
    ChatRing::NativeHandling::AutomationEffectCollector.record_message(message)
    message
  end
end
