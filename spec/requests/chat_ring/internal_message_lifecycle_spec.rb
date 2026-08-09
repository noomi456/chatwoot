require 'rails_helper'

RSpec.describe 'ChatRing internal Web Widget message lifecycle', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_widget, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, email: 'visitor@example.com') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Website Assistant') }
  let(:token) do
    Widget::TokenService.new(
      payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
    ).generate_token
  end

  before do
    inbox.update!(greeting_enabled: false, enable_email_collect: false)
    publish_and_bind_assistant!
  end

  it 'creates one internally sourced turn after native handling without a webhook delivery' do
    message = post_widget_message('What plans do you offer?')
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)

    expect(turn).to be_status_received
    expect(turn.native_handling_snapshot).to include(
      'trigger_message_id' => message.id,
      'greeting_message_ids' => [],
      'email_input_message_ids' => [],
      'out_of_office_message_ids' => []
    )
    expect(ChatRing::WebhookDelivery.count).to eq(0)
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once.with(turn.id)
  end

  it 'records the native greeting and allows one AI turn afterward' do
    inbox.update!(greeting_enabled: true, greeting_message: 'Welcome to ChatRing')

    message = post_widget_message('What plans do you offer?')
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    greeting = message.conversation.messages.template.find_by!(content: 'Welcome to ChatRing')

    expect(turn).to be_status_received
    expect(turn.native_handling_snapshot.fetch('greeting_message_ids')).to eq([greeting.id])
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once.with(turn.id)
  end

  it 'keeps email collection terminal on later messages while the Contact email is absent' do
    contact.update!(email: nil)
    inbox.update!(enable_email_collect: true)

    first_message = post_widget_message('I need help')
    second_message = post_widget_message('Are you there?')
    first_turn = ChatRing::AiTurn.find_by!(trigger_message: first_message)
    second_turn = ChatRing::AiTurn.find_by!(trigger_message: second_message)

    expect(first_turn).to be_status_ineligible
    expect(first_turn.decision_type).to eq('native_email_collection')
    expect(second_turn).to be_status_ineligible
    expect(second_turn.decision_type).to eq('native_email_collection')
    expect(second_turn.native_handling_snapshot.fetch('email_collection_required')).to be(true)
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  it 'records native out-of-office handling and does not enqueue inference' do
    inbox.update!(working_hours_enabled: true, out_of_office_message: 'We are currently closed')
    inbox.working_hours.find_by!(day_of_week: Time.zone.today.wday).update!(closed_all_day: true, open_all_day: false)

    message = post_widget_message('What plans do you offer?')
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    out_of_office = message.conversation.messages.template.find_by!(content: 'We are currently closed')

    expect(turn).to be_status_ineligible
    expect(turn.decision_type).to eq('native_out_of_office')
    expect(turn.native_handling_snapshot.fetch('out_of_office_message_ids')).to eq([out_of_office.id])
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  it 'does not affect an unbound native Web Widget inbox' do
    ChatRing::InboxAssistantBinding.delete_all
    AgentBotInbox.delete_all

    message = post_widget_message('Hello')

    expect(message).to be_persisted
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
  end

  it 'fails closed at scheduling when a conflicting automation bypasses binding validation' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      active: false,
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Automation reply'] }]
    )
    rule.update_columns(active: true, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    clear_enqueued_jobs

    message = post_widget_message('Can the Assistant answer this?')
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)

    expect(turn).to be_status_ineligible
    expect(turn.decision_type).to eq('automation_conflict')
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  private

  def publish_and_bind_assistant!
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { instructions: 'Answer from evidence.', identity: { name: assistant.name } }
    ).call
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end

  def post_widget_message(content)
    post api_v1_widget_messages_url,
         params: {
           website_token: channel.website_token,
           message: { content: content, timestamp: Time.current }
         },
         headers: { 'X-Auth-Token' => token },
         as: :json

    expect(response).to have_http_status(:success)
    Message.find(response.parsed_body.fetch('id'))
  end
end
