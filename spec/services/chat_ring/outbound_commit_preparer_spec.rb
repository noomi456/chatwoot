require 'rails_helper'

RSpec.describe ChatRing::OutboundCommitPreparer do
  it 'creates one durable pending outcome before delivery and reuses it idempotently' do
    turn = build_turn

    first = described_class.call(turn, 'reply')
    second = described_class.call(turn, 'reply')

    expect(second).to eq(first)
    expect(first).to have_attributes(status: 'pending', outcome_type: 'reply', ai_turn: turn)
    expect(ChatRing::OutboundCommit.where(ai_turn: turn).count).to eq(1)
  end

  def build_turn # rubocop:disable Metrics/MethodLength
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    version = ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               sender: conversation.contact, message_type: :incoming, private: false)
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: conversation,
      trigger_message: message,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: version,
      expected_agent_bot: connection.agent_bot,
      status: :running,
      deadline_at: 1.minute.from_now
    )
  end
end
