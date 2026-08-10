class ChatRing::AssistantManagement::Publisher
  class InvalidRevision < StandardError; end

  def initialize(assistant:, expected_lock_version:)
    @assistant = assistant
    @expected_lock_version = Integer(expected_lock_version, exception: false)
    raise InvalidRevision, 'Draft revision must be an integer' if @expected_lock_version.nil?
  end

  def call
    assistant.workspace.chatwoot_account.with_lock do
      assistant.with_lock do
        reject_archived_assistant!
        draft = assistant.configuration_draft || raise(ActiveRecord::RecordNotFound, 'Assistant draft is missing')
        draft.with_lock do
          raise ActiveRecord::StaleObjectError.new(draft, 'publish') unless draft.lock_version == expected_lock_version

          if published_revision_current?(draft)
            ensure_managed_agent_bot!
            draft.published_version
          else
            publish_new_version!(draft)
          end
        end
      end
    end
  end

  private

  attr_reader :assistant, :expected_lock_version

  def reject_archived_assistant!
    return unless assistant.archived?

    assistant.errors.add(:base, 'archived Assistant cannot publish a version')
    raise ActiveRecord::RecordInvalid, assistant
  end

  def publish_new_version!(draft)
    version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: draft.knowledge_scope,
      configuration: draft.published_configuration
    ).call
    ensure_managed_agent_bot!
    draft.update!(published_version: version)
    version
  end

  def ensure_managed_agent_bot!
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
  end

  def published_revision_current?(draft)
    version = draft.published_version
    return false if version.blank? || assistant.current_version_id != version.id
    return false if draft.knowledge_scope_id != version.knowledge_scope_id

    draft.published_configuration.all? { |attribute, value| version.public_send(attribute) == value }
  end
end
