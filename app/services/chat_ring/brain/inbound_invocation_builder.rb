class ChatRing::Brain::InboundInvocationBuilder
  MAX_HISTORY_MESSAGES = 20
  MAX_HISTORY_CHARACTERS = 16_000
  MAX_MESSAGE_CHARACTERS = 4000
  MAX_RETRIEVAL_QUERY_CHARACTERS = ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH

  def initialize(turn)
    @turn = turn
  end

  def build
    validate_supported_policies!
    history, provenance = bounded_history
    trigger = project_message(turn.trigger_message)
    native_messages, native_provenance = current_turn_native_messages
    provenance.concat(native_provenance)
    provenance << provenance_for(turn.trigger_message, trigger.fetch('speaker'))

    ChatRing::Brain::Invocation.new(
      kind: 'inbound_conversation',
      trusted_context: trusted_context,
      model_context: model_context(history, trigger, native_messages),
      audit_metadata: audit_metadata(provenance),
      query: trigger.fetch('content').first(MAX_RETRIEVAL_QUERY_CHARACTERS),
      deadline_at: turn.deadline_at
    )
  end

  private

  attr_reader :turn

  def validate_supported_policies!
    version = turn.assistant_version
    raise ArgumentError, 'Audience policy is not supported in this release' if version.audience_policy.present?
    raise ArgumentError, 'Availability policy is not supported in this release' if version.availability_policy.present?
  end

  def trusted_context
    conversation = turn.conversation
    {
      'workspace_id' => turn.workspace_id,
      'account_id' => conversation.account_id,
      'inbox_id' => conversation.inbox_id,
      'conversation_id' => conversation.id,
      'contact_id' => conversation.contact_id,
      'trigger_message_id' => turn.trigger_message_id,
      'binding_id' => turn.inbox_assistant_binding_id,
      'binding_version' => turn.binding_version,
      'assistant_id' => turn.assistant_id,
      'assistant_version_id' => turn.assistant_version_id,
      'expected_agent_bot_id' => turn.expected_agent_bot_id,
      'channel_type' => conversation.inbox.channel_type,
      'inbox_within_working_hours' => !conversation.inbox.out_of_office?
    }
  end

  def model_context(history, trigger, native_messages)
    version = turn.assistant_version
    {
      'assistant' => {
        'identity' => version.identity,
        'goals' => version.goals,
        'instructions' => version.instructions,
        'response_guidelines' => version.response_guidelines,
        'guardrails' => version.guardrails,
        'handoff_policy' => version.handoff_policy,
        'conversation_policy' => version.conversation_policy
      },
      'conversation' => {
        'channel_type' => turn.conversation.inbox.channel_type,
        'history' => history
      },
      'current_turn_native_messages' => native_messages,
      'trigger_message' => trigger
    }
  end

  def audit_metadata(provenance)
    {
      'projection_version' => 1,
      'contact_fields_included' => [],
      'speaker_provenance' => provenance
    }
  end

  def bounded_history
    messages = turn.conversation.messages
                   .where(message_type: [:incoming, :outgoing, :template], private: false)
                   .where('id < ?', turn.trigger_message_id)
                   .reorder(id: :desc)
                   .limit(MAX_HISTORY_MESSAGES * 2)

    selected = []
    provenance = []
    character_count = 0
    messages.each do |message|
      item = project_message(message)
      next if item['content'].blank?
      break if character_count + item['content'].length > MAX_HISTORY_CHARACTERS

      selected.prepend(item)
      provenance.prepend(provenance_for(message, item.fetch('speaker')))
      character_count += item['content'].length
      break if selected.length >= MAX_HISTORY_MESSAGES
    end
    [selected, provenance]
  end

  def current_turn_native_messages
    messages = turn.conversation.messages
                   .where(id: current_turn_template_ids, message_type: :template, private: false)
                   .reorder(:id)
    projected = messages.map { |message| project_message(message) }
    provenance = messages.zip(projected).map { |message, item| provenance_for(message, item.fetch('speaker')) }
    [projected, provenance]
  end

  def current_turn_template_ids
    Array(turn.native_handling_snapshot['template_delta_ids']).map(&:to_i).uniq
  end

  def project_message(message)
    speaker = speaker_for(message)
    {
      'role' => speaker == 'customer' ? 'user' : 'assistant',
      'speaker' => speaker,
      'content' => message.content_for_llm.to_s.scrub.strip.first(MAX_MESSAGE_CHARACTERS),
      'created_at' => message.created_at&.iso8601
    }
  end

  def speaker_for(message)
    return 'customer' if message.incoming? && message.sender_type == 'Contact'
    return 'native_template' if message.template?
    return 'automation' if message.content_attributes['automation_rule_id'].present?
    return 'human_agent' if message.public_human_reply?
    return agent_bot_speaker(message) if message.sender_type == 'AgentBot'

    'external_bot_or_system'
  end

  def agent_bot_speaker(message)
    managed_agent_bot?(message) ? 'managed_ai' : 'external_bot_or_system'
  end

  def managed_agent_bot?(message)
    message.sender&.chatring_assistant? && message.sender.account_id == turn.workspace.chatwoot_account_id
  end

  def provenance_for(message, speaker)
    {
      'message_id' => message.id,
      'speaker' => speaker,
      'sender_type' => message.sender_type,
      'sender_id' => message.sender_id,
      'automation_rule_id' => message.content_attributes['automation_rule_id'],
      'template_kind' => template_kind(message)
    }.compact
  end

  def template_kind(message)
    return unless message.template?

    snapshot = turn.native_handling_snapshot
    return 'greeting' if Array(snapshot['greeting_message_ids']).include?(message.id)
    return 'email_collection' if Array(snapshot['email_input_message_ids']).include?(message.id)
    return 'out_of_office' if Array(snapshot['out_of_office_message_ids']).include?(message.id)

    'native_template'
  end
end
