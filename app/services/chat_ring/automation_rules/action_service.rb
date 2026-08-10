module ChatRing::AutomationRules::ActionService
  LIFECYCLE_ACTIONS = %i[
    mute_conversation snooze_conversation resolve_conversation open_conversation pending_conversation change_status
    assign_agent remove_assigned_agent assign_team remove_assigned_team
  ].freeze

  def perform
    return super unless ChatRing::NativeHandling::AutomationEffectCollector.active?

    before = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation, rule: @rule)
    result = super
    after = ChatRing::NativeHandling::AutomationEffectCollector.conversation_snapshot(@conversation, rule: @rule)
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

  def observe_lifecycle_action
    return yield unless ChatRing::NativeHandling::AutomationEffectCollector.active?

    before = ChatRing::NativeHandling::AutomationEffectCollector.lifecycle_snapshot(@conversation)
    yield
  ensure
    after = ChatRing::NativeHandling::AutomationEffectCollector.lifecycle_snapshot(@conversation)
    ChatRing::NativeHandling::AutomationEffectCollector.record_lifecycle_transition(
      rule: @rule,
      before: before,
      after: after
    )
  end

  LIFECYCLE_ACTIONS.each do |action_name|
    define_method(action_name) do |params|
      observe_lifecycle_action { super(params) }
    end
  end

  private(*LIFECYCLE_ACTIONS)
end
