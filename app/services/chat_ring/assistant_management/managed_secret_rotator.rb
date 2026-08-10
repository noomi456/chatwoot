class ChatRing::AssistantManagement::ManagedSecretRotator
  def initialize(assistant:)
    @assistant = assistant
  end

  def call
    assistant.workspace.chatwoot_account.with_lock do
      assistant.with_lock do
        reject_archived_assistant!
        connection = assistant.agent_bot_connection
        raise ActiveRecord::RecordNotFound, 'Managed AgentBot connection is missing' if connection.blank?

        connection.with_lock do
          connection.agent_bot.reset_secret!
          connection.update!(last_verified_at: Time.current)
        end
        connection
      end
    end
  end

  private

  attr_reader :assistant

  def reject_archived_assistant!
    return unless assistant.archived?

    assistant.errors.add(:base, 'archived Assistant cannot rotate its managed secret')
    raise ActiveRecord::RecordInvalid, assistant
  end
end
