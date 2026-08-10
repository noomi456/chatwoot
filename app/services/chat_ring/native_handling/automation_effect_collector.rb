class ChatRing::NativeHandling::AutomationEffectCollector
  THREAD_KEY = :chatring_native_automation_effects
  LIFECYCLE_ATTRIBUTES = %i[status assignee_id assignee_agent_bot_id team_id].freeze

  class << self
    def capture
      previous = Thread.current[THREAD_KEY]
      state = {
        effects: [],
        public_message_ids: [],
        private_message_ids: [],
        lifecycle_changed_rule_ids: [],
        lifecycle_observation_errors: {}
      }
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
        after: after,
        lifecycle_changed: lifecycle_changed?(rule),
        lifecycle_observation_error: lifecycle_observation_error(rule)
      }
    end

    def record_message(message)
      return unless active? && message.is_a?(Message)

      key = message.private? ? :private_message_ids : :public_message_ids
      Thread.current[THREAD_KEY][key] << message.id
    end

    def record_lifecycle_transition(rule:, before:, after:)
      return unless active?

      error = before[:observation_error] || after[:observation_error]
      if error
        Thread.current[THREAD_KEY][:lifecycle_observation_errors][rule.id] = error
      elsif LIFECYCLE_ATTRIBUTES.any? { |attribute| before[attribute] != after[attribute] }
        Thread.current[THREAD_KEY][:lifecycle_changed_rule_ids] << rule.id
      end
    end

    def conversation_snapshot(conversation, rule:)
      ApplicationRecord.transaction(requires_new: true) { build_conversation_snapshot(conversation, rule) }
    rescue StandardError => e
      { observation_error: e.class.name }
    end

    def lifecycle_snapshot(conversation)
      ApplicationRecord.transaction(requires_new: true) do
        conversation.reload
        LIFECYCLE_ATTRIBUTES.index_with { |attribute| conversation.public_send(attribute) }
      end
    rescue StandardError => e
      { observation_error: e.class.name }
    end

    private

    def build_conversation_snapshot(conversation, rule)
      conversation.reload
      persisted_ids = persisted_automation_message_ids(conversation, rule)
      {
        status: conversation.status,
        assignee_id: conversation.assignee_id,
        assignee_agent_bot_id: conversation.assignee_agent_bot_id,
        team_id: conversation.team_id,
        priority: conversation.priority,
        labels: conversation.label_list.sort,
        automation_public_message_ids: (persisted_ids[:public] + Thread.current[THREAD_KEY][:public_message_ids]).uniq,
        automation_private_message_ids: (persisted_ids[:private] + Thread.current[THREAD_KEY][:private_message_ids]).uniq
      }
    end

    def persisted_automation_message_ids(conversation, rule)
      messages = conversation.messages.where.not(content_attributes: {}).pluck(:id, :private, :content_attributes)
      messages.each_with_object({ public: [], private: [] }) do |(id, private, attributes), ids|
        next unless attributes['automation_rule_id'].to_s == rule.id.to_s

        ids[private ? :private : :public] << id
      end
    end

    def lifecycle_changed?(rule)
      Thread.current[THREAD_KEY][:lifecycle_changed_rule_ids].include?(rule.id)
    end

    def lifecycle_observation_error(rule)
      Thread.current[THREAD_KEY][:lifecycle_observation_errors][rule.id]
    end
  end
end
