require 'rails_helper'

RSpec.describe ChatRing::AiTurnRecoverySweepJob, type: :job do
  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    allow(ChatRing::AiTurnRecoveryJob).to receive(:perform_later)
      .and_return(instance_double(ActiveJob::Base, successfully_enqueued?: true))
  end

  it 'enqueues persisted turns whose normal execution or outcome dispatch was lost' do
    queued_turn = create_turn(status: :received, deadline_at: 1.minute.from_now, updated_at: 2.minutes.ago)
    ready_turn = create_turn(status: :ready_to_commit, deadline_at: 1.minute.from_now)
    expired_turn = create_turn(status: :running, deadline_at: 1.minute.ago)
    create_turn(status: :running, deadline_at: 1.minute.from_now)
    create_turn(status: :failed, deadline_at: 1.minute.ago)

    described_class.perform_now

    expect(ChatRing::AiTurnRecoveryJob).to have_received(:perform_later).with(queued_turn.id)
    expect(ChatRing::AiTurnRecoveryJob).to have_received(:perform_later).with(ready_turn.id)
    expect(ChatRing::AiTurnRecoveryJob).to have_received(:perform_later).with(expired_turn.id)
    expect(ChatRing::AiTurnRecoveryJob).to have_received(:perform_later).exactly(3).times
  end

  it 'terminalizes due work while the public gate is closed without a customer mutation' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)
    queued_turn = create_turn(status: :received, deadline_at: 1.minute.from_now, updated_at: 2.minutes.ago)
    running_turn = create_turn(status: :running, deadline_at: 1.minute.ago)
    running_attempt = running_turn.attempts.create!(
      attempt_number: 1,
      provider: 'openai',
      model: 'gpt-5.4',
      status: :running,
      request_digest: Digest::SHA256.hexdigest('gate-closed-attempt'),
      started_at: 1.minute.ago
    )
    ready_turn = create_turn(status: :ready_to_commit, deadline_at: 1.minute.from_now)
    ready_turn.update!(decision_type: 'handoff')
    pending_outcome = ChatRing::OutboundCommitPreparer.call(ready_turn, 'handoff')
    allow(ChatRing::AiTurnRecoveryJob).to receive(:perform_later) do |turn_id|
      ChatRing::AiTurnRecoveryJob.perform_now(turn_id)
      instance_double(ActiveJob::Base, successfully_enqueued?: true)
    end

    expect { described_class.perform_now }.not_to change(Message, :count)

    expect(queued_turn.reload).to be_status_cancelled
    expect(running_turn.reload).to be_status_cancelled
    expect(running_attempt.reload).to have_attributes(status: 'failed', failure_code: 'public_response_gate_closed')
    expect(ready_turn.reload).to be_status_cancelled
    expect(pending_outcome.reload).to have_attributes(status: 'rejected', failure_code: 'public_response_gate_closed')
    expect([queued_turn, running_turn, ready_turn].map { |turn| turn.conversation.reload.status }).to all(eq('pending'))
  end

  it 'terminalizes a waiting Playbook with no recoverable AI turn while the public gate is closed' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)
    context = ChatRing::Playbooks::InitialQuestionPreparerSpecSupport.build
    turn = context.fetch(:turn)
    execution = turn.inbox_playbook_execution
    execution.update!(status: :waiting_for_customer)
    turn.update!(status: :committed, completed_at: Time.current)

    expect { described_class.perform_now }.not_to change(Message, :count)

    expect(execution.reload).to be_status_superseded
    expect(execution.transition_history.last).to include(
      'action' => 'public_response_gate_closed',
      'failure_code' => 'public_response_gate_closed'
    )
    expect(turn.reload).to be_status_committed
  end

  it 'leaves rejected recovery enqueue work due for the next condition-driven sweep' do
    turn = create_turn(status: :received, deadline_at: 1.minute.from_now, updated_at: 2.minutes.ago)
    accepted_job = instance_double(ActiveJob::Base, successfully_enqueued?: true)
    allow(ChatRing::AiTurnRecoveryJob).to receive(:perform_later).with(turn.id).and_return(false, accepted_job)

    described_class.perform_now
    described_class.perform_now

    expect(ChatRing::AiTurnRecoveryJob).to have_received(:perform_later).with(turn.id).twice
  end

  def create_turn(status:, deadline_at:, updated_at: Time.current)
    build_turn(status: status, deadline_at: deadline_at, updated_at: updated_at)
  end

  def build_turn(status:, deadline_at:, updated_at:) # rubocop:disable Metrics/MethodLength
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: "Assistant #{SecureRandom.hex(4)}")
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    version = ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :incoming, sender: conversation.contact)
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: conversation,
      trigger_message: message,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: version,
      expected_agent_bot: connection.agent_bot,
      status: status,
      deadline_at: deadline_at,
      created_at: updated_at,
      updated_at: updated_at
    )
  end
end
