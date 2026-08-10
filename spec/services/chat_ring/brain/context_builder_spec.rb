require 'rails_helper'

RSpec.describe ChatRing::Brain::ContextBuilder do
  let(:turn) { build_turn }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  it 'uses only bounded public conversation history and trusted base Contact fields' do
    trigger = turn.trigger_message
    trigger.update!(content: 'Current question')

    context = described_class.new(turn).build

    expect(context.dig('conversation', 'history').pluck('content')).to eq(['Earlier public'])
    expect(context.dig('trigger_message', 'content')).to eq('Current question')
    expect(context.fetch('contact')).to include('chatwoot_contact_id' => turn.conversation.contact_id)
    expect(context.to_json).not_to include('Private note')
  end

  def build_turn
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :incoming, sender: conversation.contact, content: 'Earlier public')
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :outgoing, sender: create(:user), content: 'Private note', private: true)
    message = create_managed_message(account: account, inbox: inbox, conversation: conversation)
    complete_native_automation(message)
    ChatRing::AiTurn.find_by!(workspace: workspace, conversation: conversation, trigger_message: message)
  end

  def create_managed_message(account:, inbox:, conversation:)
    ChatRing::ConversationWriteBoundary.new(conversation: conversation).call do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, sender: conversation.contact, private: false)
    end
  end

  def complete_native_automation(message)
    EventDispatcherJob.perform_now(Message::MESSAGE_CREATED, message.created_at, { message: message, performed_by: nil })
  end
end
