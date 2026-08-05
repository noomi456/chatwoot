class ChatRing::AssistantSpike::ResponseJob < ApplicationJob
  queue_as :medium

  def perform(triggering_message_id)
    triggering_message = Message.find_by(id: triggering_message_id)
    return discard(triggering_message_id, 'missing_message') if triggering_message.blank?
    return discard(triggering_message_id, 'ineligible') unless ChatRing::AssistantSpike.eligible_message?(triggering_message)
    return discard(triggering_message_id, 'newer_message') if newer_customer_message?(triggering_message)

    commit_response(triggering_message)
  end

  private

  def commit_response(triggering_message)
    triggering_message.conversation.with_lock do
      triggering_message.reload
      unless ChatRing::AssistantSpike.eligible_message?(triggering_message)
        return discard(triggering_message.id, 'ineligible_at_commit')
      end

      return discard(triggering_message.id, 'newer_message_at_commit') if newer_customer_message?(triggering_message)

      source_id = ChatRing::AssistantSpike.response_source_id(triggering_message)
      if Message.exists?(account_id: triggering_message.account_id, source_id: source_id)
        return discard(triggering_message.id, 'already_replied')
      end

      triggering_message.conversation.messages.create!(
        account_id: triggering_message.account_id,
        inbox_id: triggering_message.inbox_id,
        message_type: :outgoing,
        sender: ChatRing::AssistantSpike.internal_bot_for(triggering_message.inbox),
        content: "RECEIVED #{triggering_message.content}",
        source_id: source_id,
        additional_attributes: {
          ChatRing::AssistantSpike::BOT_CONFIG_KEY => true,
          'triggering_message_id' => triggering_message.id
        }
      )
    end
  end

  def newer_customer_message?(triggering_message)
    triggering_message.conversation.messages.incoming.where(private: false).where('id > ?', triggering_message.id).exists?
  end

  def discard(triggering_message_id, reason)
    Rails.logger.info("[ChatRing::AssistantSpike] discard triggering_message_id=#{triggering_message_id} reason=#{reason}")
    nil
  end
end
