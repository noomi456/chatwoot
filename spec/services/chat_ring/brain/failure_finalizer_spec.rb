require 'rails_helper'

RSpec.describe ChatRing::Brain::FailureFinalizer do
  it 'records the configured safe terminal decision after bounded provider retries' do
    turn = build_turn

    expect do
      described_class.call(turn.id, 'provider_failed')
    end.not_to change(Message, :count)

    expect(turn.reload).to be_status_ready_to_commit
    expect(turn.decision_payload).to include('decision_type' => 'handoff', 'reason_code' => 'provider_failure')
    expect(turn.failure_code).to eq('provider_failed')
  end

  def build_turn # rubocop:disable Metrics/MethodLength
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:inbox, account: account)
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { handoff_policy: { 'on_provider_failure' => 'handoff' } }
    ).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :incoming, sender: conversation.contact, private: false)
    ChatRing::AiTurn.create!(workspace: workspace, conversation: conversation, trigger_message: message,
                             inbox_assistant_binding: binding, binding_version: binding.binding_version,
                             assistant: assistant, assistant_version: version,
                             expected_agent_bot: connection.agent_bot, status: :received)
  end
end
