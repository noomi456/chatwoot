require 'rails_helper'

RSpec.describe ChatRing::Brain::ContextBuilder do
  let(:turn) { build_turn }

  it 'uses only bounded public conversation history and trusted base Contact fields' do
    trigger = turn.trigger_message
    trigger.update!(content: 'Current question')

    context = described_class.new(turn).build

    expect(context.dig('conversation', 'history').pluck('content')).to eq(['Earlier public'])
    expect(context.dig('trigger_message', 'content')).to eq('Current question')
    expect(context.fetch('contact')).to include('chatwoot_contact_id' => turn.conversation.contact_id)
    expect(context.to_json).not_to include('Private note')
  end

  def build_turn # rubocop:disable Metrics/MethodLength
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:inbox, account: account)
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    version = ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :incoming, sender: conversation.contact, content: 'Earlier public')
    create(:message, conversation: conversation, account: account, inbox: inbox,
                     message_type: :outgoing, sender: create(:user), content: 'Private note', private: true)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :incoming, sender: conversation.contact, private: false)
    ChatRing::AiTurn.create!(workspace: workspace, conversation: conversation, trigger_message: message,
                             inbox_assistant_binding: binding, binding_version: binding.binding_version,
                             assistant: assistant, assistant_version: version,
                             expected_agent_bot: connection.agent_bot, status: :received)
  end
end
