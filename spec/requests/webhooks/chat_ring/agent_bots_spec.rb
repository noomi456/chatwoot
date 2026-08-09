require 'rails_helper'

RSpec.describe 'ChatRing managed AgentBot webhooks', type: :request do
  include ActiveJob::TestHelper

  before do
    stub_const('ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED', true)
    allow(ChatRing::AiTurnJob).to receive(:perform_later)
      .and_return(instance_double(ActiveJob::Base, successfully_enqueued?: true))
  end

  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:connection) { provision_assistant }
  let(:agent_bot) { connection.agent_bot }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :pending,
      assignee_agent_bot: agent_bot
    )
  end
  let(:message) do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      sender: conversation.contact,
      private: false
    )
  end

  def provision_assistant
    knowledge_scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: knowledge_scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    connection
  end

  def payload_for(target_message = message)
    target_message.webhook_data.merge(event: 'message_created').to_json
  end

  def signed_headers(body, delivery_id: SecureRandom.uuid, timestamp: Time.current.to_i.to_s)
    digest = OpenSSL::HMAC.hexdigest('SHA256', agent_bot.secret, "#{timestamp}.#{body}")
    {
      'CONTENT_TYPE' => 'application/json',
      'X-Chatwoot-Delivery' => delivery_id,
      'X-Chatwoot-Timestamp' => timestamp,
      'X-Chatwoot-Signature' => "sha256=#{digest}"
    }
  end

  def post_webhook(body, headers)
    post "/webhooks/chatring/agent-bots/#{connection.webhook_key}", params: body, headers: headers
  end

  it 'rejects a previously valid signed managed webhook in internal runtime mode' do
    stub_const('ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED', false)
    body = payload_for

    delivery_count = ChatRing::WebhookDelivery.count
    turn_count = ChatRing::AiTurn.count
    post_webhook(body, signed_headers(body))

    expect(response).to have_http_status(:not_found)
    expect(ChatRing::WebhookDelivery.count).to eq(delivery_count)
    expect(ChatRing::AiTurn.count).to eq(turn_count)
  end

  it 'accepts a signed delivery and creates one received AI turn from fresh Chatwoot state' do
    body = payload_for

    expect do
      perform_enqueued_jobs { post_webhook(body, signed_headers(body)) }
    end.to change(ChatRing::WebhookDelivery, :count).by(1)
       .and change(ChatRing::AiTurn, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(ChatRing::WebhookDelivery.last).to be_processed
    turn = ChatRing::AiTurn.last
    expect(turn).to be_status_received
    expect(turn.trigger_message).to eq(message)
    expect(turn.assistant_version).to eq(assistant.current_version)
    expect(turn.expected_agent_bot).to eq(agent_bot)
  end

  it 'deduplicates an identical retry by delivery ID and body hash' do
    body = payload_for
    headers = signed_headers(body, delivery_id: 'delivery-retry')

    perform_enqueued_jobs { post_webhook(body, headers) }
    expect do
      perform_enqueued_jobs { post_webhook(body, headers) }
    end.not_to change(ChatRing::WebhookDelivery, :count)

    expect(response).to have_http_status(:ok)
    expect(ChatRing::AiTurn.count).to eq(1)
  end

  it 'creates one AI turn when the same message arrives under distinct delivery IDs' do
    body = payload_for

    perform_enqueued_jobs { post_webhook(body, signed_headers(body, delivery_id: 'delivery-one')) }
    perform_enqueued_jobs { post_webhook(body, signed_headers(body, delivery_id: 'delivery-two')) }

    expect(response).to have_http_status(:ok)
    expect(ChatRing::WebhookDelivery.count).to eq(2)
    expect(ChatRing::AiTurn.count).to eq(1)
  end

  it 'creates a separate turn for a newer customer message' do
    original_body = payload_for
    newer_message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      sender: conversation.contact,
      private: false,
      content: 'One more question'
    )
    newer_body = payload_for(newer_message)

    perform_enqueued_jobs { post_webhook(original_body, signed_headers(original_body, delivery_id: 'delivery-original')) }
    perform_enqueued_jobs { post_webhook(newer_body, signed_headers(newer_body, delivery_id: 'delivery-newer')) }

    expect(ChatRing::AiTurn.where(trigger_message_id: [message.id, newer_message.id]).count).to eq(2)
  end

  it 'commits one public reply across duplicate webhook delivery and commit retries' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    body = payload_for
    headers = signed_headers(body, delivery_id: 'delivery-reply-retry')

    perform_enqueued_jobs { post_webhook(body, headers) }
    perform_enqueued_jobs { post_webhook(body, headers) }
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    turn.update!(
      status: :ready_to_commit,
      decision_type: 'reply',
      decision_payload: {
        'decision_type' => 'reply',
        'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered',
        'evidence_ids' => ['evidence-1']
      }
    )

    2.times { ChatRing::OutboundCommitJob.perform_now(turn.id) }

    expect(ChatRing::AiTurn.where(trigger_message: message).count).to eq(1)
    expect(conversation.messages.outgoing.where(sender: agent_bot).pluck(:content)).to eq(['Widgets are supported.'])
  end

  it 'rejects a reused delivery ID carrying a different signed body' do
    body = payload_for
    headers = signed_headers(body, delivery_id: 'delivery-collision')
    perform_enqueued_jobs { post_webhook(body, headers) }

    changed_body = JSON.parse(body).merge('content' => 'different').to_json
    post_webhook(changed_body, signed_headers(changed_body, delivery_id: 'delivery-collision'))

    expect(response).to have_http_status(:conflict)
    expect(ChatRing::WebhookDelivery.count).to eq(1)
    expect(ChatRing::AiTurn.count).to eq(1)
  end

  it 'rejects invalid and stale signatures without persisting untrusted input' do
    body = payload_for
    invalid_headers = signed_headers(body).merge('X-Chatwoot-Signature' => "sha256=#{('0' * 64)}")
    post_webhook(body, invalid_headers)
    expect(response).to have_http_status(:unauthorized)

    old_timestamp = 10.minutes.ago.to_i.to_s
    post_webhook(body, signed_headers(body, timestamp: old_timestamp))
    expect(response).to have_http_status(:unauthorized)
    expect(ChatRing::WebhookDelivery.count).to eq(0)
  end

  it 'rejects a valid signature whose payload names another account' do
    body = JSON.parse(payload_for).tap { |payload| payload['account']['id'] = create(:account).id }.to_json
    post_webhook(body, signed_headers(body))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(ChatRing::WebhookDelivery.count).to eq(0)
  end

  it 'records an ineligible turn when ownership changes before processing' do
    body = payload_for
    headers = signed_headers(body)
    allow(ChatRing::WebhookDeliveryJob).to receive(:perform_later) do |delivery_id|
      conversation.update!(status: :open, assignee_agent_bot: nil)
      ChatRing::WebhookDeliveryJob.perform_now(delivery_id)
      instance_double(ActiveJob::Base, successfully_enqueued?: true)
    end

    post_webhook(body, headers)

    expect(response).to have_http_status(:ok)
    turn = ChatRing::AiTurn.last
    expect(turn).to be_status_ineligible
    expect(turn.decision_type).to eq('conversation_not_pending')
  end

  it 'returns a retryable server error when the durable delivery cannot be enqueued' do
    body = payload_for
    allow(ChatRing::WebhookDeliveryJob).to receive(:perform_later).and_return(false)

    post_webhook(body, signed_headers(body))

    expect(response).to have_http_status(:internal_server_error)
    expect(ChatRing::WebhookDelivery.last).to be_received
    expect(ChatRing::AiTurn.count).to eq(0)
  end

  it 'keeps a durable turn retryable when the Brain job cannot be enqueued' do
    body = payload_for
    post_webhook(body, signed_headers(body))
    delivery = ChatRing::WebhookDelivery.last
    allow(ChatRing::AiTurnJob).to receive(:perform_later).and_return(false)

    expect do
      ChatRing::WebhookDeliveryJob.perform_now(delivery.id)
    end.to raise_error(RuntimeError, 'ChatRing AI turn could not be queued')

    expect(delivery.reload).to be_received
    expect(ChatRing::AiTurn.find_by!(trigger_message: message)).to be_status_received
  end

  it 'removes runtime delivery and turn records when their Workspace is destroyed' do
    body = payload_for
    perform_enqueued_jobs { post_webhook(body, signed_headers(body)) }
    index = workspace.knowledge_base.knowledge_indexes.create!(
      workspace: workspace,
      status: 'building',
      provider_release: 'provider-release',
      mapped_manifest: [],
      manifest_digest: Digest::SHA256.hexdigest('manifest')
    )
    turn = ChatRing::AiTurn.last
    turn.update!(knowledge_index: index)
    turn.evidence.create!(
      position: 0, evidence_id: 'evidence-1', knowledge_index: index, source_kind: 'website',
      source_reference: 'https://example.com/', source_title: 'Example', excerpt: 'Example evidence',
      source_content_hash: Digest::SHA256.hexdigest('content'), rank: 1, score: 0.8
    )

    expect do
      workspace.destroy!
    end.to change(ChatRing::WebhookDelivery, :count).by(-1)
       .and change(ChatRing::AiTurn, :count).by(-1)
  end
end
