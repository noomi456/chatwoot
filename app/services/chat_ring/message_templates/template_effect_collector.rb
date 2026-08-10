class ChatRing::MessageTemplates::TemplateEffectCollector
  THREAD_KEY = :chatring_native_template_effects
  EMPTY_EFFECTS = {
    greeting_message_ids: [],
    email_input_message_ids: [],
    out_of_office_message_ids: [],
    observation_error: nil
  }.freeze

  class << self
    def capture
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = EMPTY_EFFECTS.deep_dup
      yield
      Thread.current[THREAD_KEY]
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def active?
      Thread.current[THREAD_KEY].present?
    end

    def observe(kind, conversation)
      return yield unless active?

      before = safely_snapshot(conversation)
      result = yield
      after = safely_snapshot(conversation)
      record(kind, before, after) if before && after
      result
    end

    private

    def safely_snapshot(conversation)
      snapshot_rows(conversation)
    rescue StandardError => e
      Thread.current[THREAD_KEY][:observation_error] ||= e.class.name
      Rails.logger.error("[ChatRing] template provenance observation failed conversation_id=#{conversation.id} error=#{e.class.name}")
      nil
    end

    def snapshot_rows(conversation)
      conversation.messages.template.reorder(:id).pluck(:id, :content_type)
    end

    def record(kind, before, after)
      before_ids = before.map(&:first)
      delta = after.reject { |entry| before_ids.include?(entry.first) }
      ids = if kind == :email_collection
              delta.filter_map { |id, content_type| id if content_type == 'input_email' }
            else
              delta.map(&:first)
            end
      Thread.current[THREAD_KEY][effect_key(kind)].concat(ids).uniq!
    end

    def effect_key(kind)
      {
        greeting: :greeting_message_ids,
        email_collection: :email_input_message_ids,
        out_of_office: :out_of_office_message_ids
      }.fetch(kind)
    end
  end
end
