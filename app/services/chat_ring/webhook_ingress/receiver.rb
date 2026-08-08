class ChatRing::WebhookIngress::Receiver
  Result = Data.define(:delivery, :duplicate)

  class InvalidPayload < StandardError; end
  class ScopeMismatch < StandardError; end
  class DeliveryCollision < StandardError; end

  def initialize(connection:, raw_body:, headers:)
    @connection = connection
    @raw_body = raw_body
    @headers = headers
  end

  def call
    verify_signature!
    payload = parse_payload!
    attributes = delivery_attributes(payload)
    verify_scope!(attributes)
    persist_delivery!(attributes)
  end

  private

  attr_reader :connection, :raw_body, :headers

  def verify_signature!
    ChatRing::WebhookIngress::SignatureVerifier.new(
      secret: connection.agent_bot.secret,
      raw_body: raw_body,
      timestamp: headers['X-Chatwoot-Timestamp'],
      signature: headers['X-Chatwoot-Signature']
    ).verify!
  end

  def parse_payload!
    payload = JSON.parse(raw_body)
    return payload if payload.is_a?(Hash)

    raise InvalidPayload, 'webhook payload must be an object'
  rescue JSON::ParserError
    raise InvalidPayload, 'webhook payload is not valid JSON'
  end

  def delivery_attributes(payload)
    {
      workspace: connection.workspace,
      assistant_agent_bot_connection: connection,
      delivery_id: required_header('X-Chatwoot-Delivery'),
      event_type: required_string(payload['event'], 'event'),
      payload_account_id: positive_id(payload.dig('account', 'id'), 'account.id'),
      payload_inbox_id: positive_id(payload.dig('inbox', 'id') || payload['inbox_id'], 'inbox.id'),
      payload_conversation_id: optional_id(payload.dig('conversation', 'id') || conversation_event_id(payload)),
      payload_message_id: message_event?(payload) ? optional_id(payload['id']) : nil,
      payload_hash: Digest::SHA256.hexdigest(raw_body),
      verification_status: :verified,
      processing_status: :received,
      received_at: Time.current
    }
  end

  def verify_scope!(attributes)
    verify_connection!
    verify_payload_account!(attributes[:payload_account_id])
    verify_inbox_binding!(attributes[:payload_inbox_id])
  end

  def verify_connection!
    workspace = connection.workspace
    account_id = workspace.chatwoot_account_id
    valid_connection = connection.active? &&
                       connection.agent_bot.chatring_assistant? &&
                       connection.agent_bot.account_id == account_id
    return if valid_connection

    raise ScopeMismatch, 'inactive or invalid AgentBot connection'
  end

  def verify_payload_account!(payload_account_id)
    return if payload_account_id == connection.workspace.chatwoot_account_id

    raise ScopeMismatch, 'payload Account does not match the AgentBot connection'
  end

  def verify_inbox_binding!(payload_inbox_id)
    inbox = Inbox.find_by(id: payload_inbox_id, account_id: connection.workspace.chatwoot_account_id)
    binding = connection.inbox_bindings.active.find_by(chatwoot_inbox_id: inbox&.id)
    agent_bot_inbox = AgentBotInbox.active.find_by(inbox_id: inbox&.id, agent_bot_id: connection.agent_bot_id)
    return if inbox.present? && binding.present? && agent_bot_inbox.present?

    raise ScopeMismatch, 'payload Inbox is not actively bound to the AgentBot connection'
  end

  def persist_delivery!(attributes)
    existing = ChatRing::WebhookDelivery.find_by(delivery_id: attributes[:delivery_id])
    return duplicate_result(existing, attributes) if existing.present?

    Result.new(ChatRing::WebhookDelivery.create!(attributes), false)
  rescue ActiveRecord::RecordNotUnique
    duplicate_result(ChatRing::WebhookDelivery.find_by!(delivery_id: attributes[:delivery_id]), attributes)
  end

  def duplicate_result(existing, attributes)
    same_delivery = existing.payload_hash == attributes[:payload_hash] &&
                    existing.assistant_agent_bot_connection_id == connection.id
    return Result.new(existing, true) if same_delivery

    raise DeliveryCollision, 'delivery ID was reused with a different payload or connection'
  end

  def required_header(name)
    value = headers[name].to_s
    raise InvalidPayload, "missing #{name}" if value.blank?
    raise InvalidPayload, "#{name} is too long" if value.length > 255

    value
  end

  def required_string(value, name)
    return value if value.is_a?(String) && value.present? && value.length <= 100

    raise InvalidPayload, "missing #{name}"
  end

  def positive_id(value, name)
    id = optional_id(value)
    return id if id&.positive?

    raise InvalidPayload, "missing or invalid #{name}"
  end

  def optional_id(value)
    return value if value.is_a?(Integer)

    Integer(value, 10) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def conversation_event_id(payload)
    payload['id'] unless message_event?(payload)
  end

  def message_event?(payload)
    payload['event'].to_s.start_with?('message_')
  end
end
