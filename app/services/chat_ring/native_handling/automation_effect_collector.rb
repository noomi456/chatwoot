class ChatRing::NativeHandling::AutomationEffectCollector
  THREAD_KEY = :chatring_native_automation_effects

  class << self
    def capture
      previous = Thread.current[THREAD_KEY]
      effects = []
      Thread.current[THREAD_KEY] = effects
      yield
      effects
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def active?
      !Thread.current[THREAD_KEY].nil?
    end

    def record(rule:, before:, after:)
      return unless active?

      Thread.current[THREAD_KEY] << {
        rule_id: rule.id,
        action_names: Array(rule.actions).map { |action| action.with_indifferent_access[:action_name].to_s },
        before: before,
        after: after
      }
    end

    def conversation_snapshot(conversation)
      ApplicationRecord.transaction(requires_new: true) { build_conversation_snapshot(conversation) }
    rescue StandardError => e
      { observation_error: e.class.name }
    end

    private

    def build_conversation_snapshot(conversation)
      conversation.reload
      {
        status: conversation.status,
        assignee_id: conversation.assignee_id,
        assignee_agent_bot_id: conversation.assignee_agent_bot_id,
        team_id: conversation.team_id,
        priority: conversation.priority,
        labels: conversation.label_list.sort,
        automation_message_ids: automation_message_ids(conversation)
      }
    end

    def automation_message_ids(conversation)
      conversation.messages
                  .where("content_attributes ->> 'automation_rule_id' IS NOT NULL")
                  .reorder(:id)
                  .pluck(:id)
    end
  end
end
