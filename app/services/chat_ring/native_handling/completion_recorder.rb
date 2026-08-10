class ChatRing::NativeHandling::CompletionRecorder
  class << self
    def start(message)
      new(message).start
    end

    def template_observation(message)
      new(message).template_observation
    end

    def record_template(message:, observation:, effects:)
      new(message).record_template(observation, effects)
    end

    def record_automation(message:, effects:)
      new(message).record_automation(effects)
    end

    def candidate?(message)
      new(message).candidate?
    end

    def potential_candidate?(message)
      new(message).potential_candidate?
    end
  end

  def initialize(message)
    @message = message
  end

  def start
    return unless potential_candidate?

    find_or_create_completion
  end

  def template_observation
    return unless candidate?

    inbox = message.conversation.inbox
    {
      template_ids_before: conversation_template_ids,
      inbox_out_of_office: inbox.out_of_office?,
      email_collection_required: email_collection_required?
    }
  end

  def record_template(observation, effects)
    return unless candidate?

    record_once(
      completed_attribute: :template_completed_at,
      snapshot_attribute: :template_snapshot,
      snapshot: template_snapshot(observation, effects)
    )
  end

  def record_automation(effects)
    return unless candidate?

    record_once(
      completed_attribute: :automation_completed_at,
      snapshot_attribute: :automation_snapshot,
      snapshot: {
        completed: true,
        matched_rule_ids: effects.pluck(:rule_id),
        effects: effects
      }
    )
  end

  def candidate?
    potential_candidate? && ChatRing::NativeHandlingCompletion.exists?(trigger_message: message)
  end

  def potential_candidate?
    runtime_open? && customer_widget_message?
  end

  private

  attr_reader :message

  def runtime_open?
    ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY && !ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED
  end

  def customer_widget_message?
    conversation = message.conversation
    agent_bot = conversation.assignee_agent_bot
    message.incoming? &&
      !message.private? &&
      message.sender_type == 'Contact' &&
      conversation.inbox.channel_type == 'Channel::WebWidget' &&
      agent_bot&.chatring_assistant?
  end

  def record_once(completed_attribute:, snapshot_attribute:, snapshot:)
    completion = find_or_create_completion
    completion.with_lock do
      unless completion.public_send(completed_attribute)
        completion.update!(
          completed_attribute => Time.current,
          snapshot_attribute => snapshot
        )
      end
    end
    release_if_complete(completion)
  end

  def find_or_create_completion
    ChatRing::NativeHandlingCompletion.create_or_find_by!(trigger_message: message)
  end

  def release_if_complete(completion)
    conversation = Conversation.find(message.conversation_id)
    inbox = Inbox.find(conversation.inbox_id)
    inbox.with_lock do
      conversation.with_lock do
        completion.with_lock do
          completion.reload
          next if completion.released_at? || !completion.template_completed_at? || !completion.automation_completed_at?

          turn = ChatRing::InternalTurnScheduler.new(
            message: message,
            native_handling_snapshot: combined_snapshot(completion)
          ).call
          completion.update!(ai_turn: turn, released_at: Time.current)
        end
      end
    end
  end

  def combined_snapshot(completion)
    completion.template_snapshot.merge('automation' => completion.automation_snapshot)
  end

  def template_snapshot(observation, effects)
    current_ids = conversation_template_ids
    template_ids_before = observation.fetch(:template_ids_before)
    {
      trigger_message_id: message.id,
      template_ids_before: template_ids_before,
      template_ids_after: current_ids,
      template_delta_ids: current_ids - template_ids_before
    }.merge(template_outcomes(observation, effects))
  end

  def template_outcomes(observation, effects)
    {
      greeting_message_ids: effects.fetch(:greeting_message_ids),
      email_input_message_ids: effects.fetch(:email_input_message_ids),
      out_of_office_message_ids: effects.fetch(:out_of_office_message_ids),
      template_observation_error: effects[:observation_error],
      inbox_out_of_office: observation[:inbox_out_of_office],
      email_collection_required: observation[:email_collection_required]
    }
  end

  def conversation_template_ids
    message.conversation.messages.template.reorder(:id).pluck(:id)
  end

  def email_collection_required?
    inbox = message.conversation.inbox
    inbox.enable_email_collect? && inbox.web_widget? && message.conversation.contact.email.blank?
  end
end
