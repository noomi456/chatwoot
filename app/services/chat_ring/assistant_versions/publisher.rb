class ChatRing::AssistantVersions::Publisher
  CONFIGURATION_ATTRIBUTES = %i[
    identity goals instructions response_guidelines guardrails audience_policy availability_policy handoff_policy tool_grants
    conversation_policy
  ].freeze

  def initialize(assistant:, knowledge_scope:, configuration: {})
    @assistant = assistant
    @knowledge_scope = knowledge_scope
    @configuration = configuration.to_h.symbolize_keys.slice(*CONFIGURATION_ATTRIBUTES)
  end

  def call
    assistant.with_lock do
      if assistant.archived?
        assistant.errors.add(:base, 'archived Assistant cannot publish a new version')
        raise ActiveRecord::RecordInvalid, assistant
      end

      version = assistant.versions.create!(
        configuration.merge(
          knowledge_scope: knowledge_scope,
          version: assistant.versions.maximum(:version).to_i + 1,
          published_at: Time.current
        )
      )
      assistant.update!(current_version: version)
      version
    end
  end

  private

  attr_reader :assistant, :knowledge_scope, :configuration
end
