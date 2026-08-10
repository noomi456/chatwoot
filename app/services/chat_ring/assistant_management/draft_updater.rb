class ChatRing::AssistantManagement::DraftUpdater
  class InvalidRevision < StandardError; end

  def initialize(assistant:, expected_lock_version:, attributes:)
    @assistant = assistant
    @expected_lock_version = Integer(expected_lock_version, exception: false)
    @attributes = attributes
    raise InvalidRevision, 'Draft revision must be an integer' if @expected_lock_version.nil?
  end

  def call
    assistant.workspace.chatwoot_account.with_lock do
      assistant.with_lock do
        reject_archived_assistant!
        update_assistant_name!
        draft = assistant.configuration_draft || raise(ActiveRecord::RecordNotFound, 'Assistant draft is missing')
        draft.with_lock do
          raise ActiveRecord::StaleObjectError.new(draft, 'update') unless draft.lock_version == expected_lock_version

          draft.update!(attributes.except(:name))
        end
      end
    end
  end

  private

  attr_reader :assistant, :expected_lock_version, :attributes

  def reject_archived_assistant!
    return unless assistant.archived?

    assistant.errors.add(:base, 'archived Assistant is read-only')
    raise ActiveRecord::RecordInvalid, assistant
  end

  def update_assistant_name!
    name = attributes[:name]
    return if name.nil? || name.strip == assistant.name

    if assistant.agent_bot_connection.present?
      assistant.errors.add(:name, 'cannot change after the managed AgentBot is provisioned')
      raise ActiveRecord::RecordInvalid, assistant
    end
    assistant.update!(name: name.strip)
  end
end
