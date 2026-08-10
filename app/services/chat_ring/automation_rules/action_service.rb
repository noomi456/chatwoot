module ChatRing::AutomationRules::ActionService
  def perform
    return super unless ChatRing::NativeHandling::AutomationEffectCollector.active?

    before = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation)
    result = super
    after = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation)
    ChatRing::NativeHandling::AutomationEffectCollector.record(rule: @rule, before: before, after: after)
    result
  end
end
