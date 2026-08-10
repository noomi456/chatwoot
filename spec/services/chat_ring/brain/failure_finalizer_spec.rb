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

  it 'still executes the configured native fallback handoff after the inference deadline' do
    turn = build_turn
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).and_return(false)
    travel_to(turn.deadline_at + 1.second)

    described_class.call(turn.id, 'provider_failed')

    expect(turn.reload).to be_status_handed_off
    expect(turn.outbound_commit).to have_attributes(status: 'committed', outcome_type: 'handoff')
    expect(turn.conversation.reload).to have_attributes(status: 'open', assignee_agent_bot_id: nil)
  end

  it 'does not overwrite a terminal turn when an exhausted duplicate arrives late' do
    turn = build_turn
    turn.update!(status: :cancelled, failure_code: 'newer_customer_message', completed_at: Time.current)

    described_class.call(turn.id, 'provider_failed')

    expect(turn.reload).to have_attributes(status: 'cancelled', failure_code: 'newer_customer_message')
    expect(turn.outbound_commit).to be_nil
  end

  it 'terminalizes an expired awaiting-tool execution through the configured native fallback' do
    turn = build_turn
    turn.update!(status: :awaiting_tool)
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).and_return(false)
    travel_to(turn.deadline_at + 1.second)

    described_class.call(turn.id, 'turn_recovery_deadline')

    expect(turn.reload).to be_status_handed_off
    expect(turn.outbound_commit).to have_attributes(status: 'committed', outcome_type: 'handoff')
  end

  it 'closes an abandoned running provider attempt before committing fallback' do
    turn = build_turn
    attempt = turn.attempts.create!(
      attempt_number: 1,
      provider: 'openai',
      model: 'gpt-5.4',
      status: :running,
      request_digest: Digest::SHA256.hexdigest('abandoned-attempt'),
      started_at: 1.minute.ago
    )
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).and_return(false)

    described_class.call(turn.id, 'turn_recovery_deadline')

    expect(attempt.reload).to have_attributes(status: 'failed', failure_code: 'turn_recovery_deadline')
    expect(attempt.completed_at).to be_present
    expect(turn.reload).to be_status_handed_off
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
