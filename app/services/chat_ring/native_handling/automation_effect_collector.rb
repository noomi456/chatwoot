class ChatRing::NativeHandling::AutomationEffectCollector
  THREAD_KEY = :chatring_native_automation_effects

  class << self
    def capture
      previous = Thread.current[THREAD_KEY]
      state = { effects: [], public_message_ids: [], private_message_ids: [] }
      Thread.current[THREAD_KEY] = state
      yield
      state[:effects]
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def active?
      !Thread.current[THREAD_KEY].nil?
    end

    def record(rule:, before:, after:)
      return unless active?

      Thread.current[THREAD_KEY][:effects] << {
        rule_id: rule.id,
        action_names: Array(rule.actions).map { |action| action.with_indifferent_access[:action_name].to_s },
        before: before,
        after: after
      }
    end

    def record_message(message)
      return unless active? && message.is_a?(Message)

      key = message.private? ? :private_message_ids : :public_message_ids
      Thread.current[THREAD_KEY][key] << message.id
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
        automation_public_message_ids: Thread.current[THREAD_KEY][:public_message_ids].dup,
        automation_private_message_ids: Thread.current[THREAD_KEY][:private_message_ids].dup
      }
    end
  end
end
