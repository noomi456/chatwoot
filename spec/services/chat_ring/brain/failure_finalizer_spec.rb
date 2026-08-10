require 'rails_helper'

RSpec.describe ChatRing::Brain::FailureFinalizer do
  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  it 'executes the configured native handoff after bounded provider retries' do
    turn = build_turn
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).and_return(false)

    expect do
      described_class.call(turn.id, 'provider_failed')
    end.not_to change(Message, :count)

    expect(turn.reload).to be_status_handed_off
    expect(turn.decision_payload).to include('decision_type' => 'handoff', 'reason_code' => 'provider_failure')
    expect(turn.failure_code).to be_nil
    expect(turn.outbound_commit).to be_status_committed
    expect(turn.conversation.reload).to have_attributes(status: 'open', assignee_agent_bot_id: nil)
  end

  it 'does not prepare a fallback outcome after the turn deadline' do
    turn = build_turn
    travel_to(turn.deadline_at + 1.second)

    described_class.call(turn.id, 'provider_failed')

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('turn_deadline_expired')
    expect(turn.decision_payload).to eq({})
  end

  def build_turn
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { handoff_policy: { 'on_provider_failure' => 'handoff' } }
    ).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
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
