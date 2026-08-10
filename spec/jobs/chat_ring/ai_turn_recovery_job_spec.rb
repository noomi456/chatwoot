require 'rails_helper'

RSpec.describe ChatRing::AiTurnRecoveryJob, type: :job do
  let(:turn) { instance_double(ChatRing::AiTurn, id: 42, deadline_at: 1.minute.ago, status: 'running') }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    allow(ChatRing::AiTurn).to receive(:find_by).with(id: 42).and_return(turn)
    allow(turn).to receive(:status_ready_to_commit?).and_return(false)
    allow(ChatRing::Brain::FailureFinalizer).to receive(:call)
    allow(ChatRing::OutboundCommitDispatcher).to receive(:call)
  end

  it 'finalizes an abandoned execution after its deadline' do
    described_class.perform_now(42)

    expect(ChatRing::Brain::FailureFinalizer).to have_received(:call).with(42, 'turn_recovery_deadline')
  end

  it 'dispatches a durable ready outcome' do
    allow(turn).to receive(:status_ready_to_commit?).and_return(true)

    described_class.perform_now(42)

    expect(ChatRing::OutboundCommitDispatcher).to have_received(:call).with(42)
    expect(ChatRing::Brain::FailureFinalizer).not_to have_received(:call)
  end

  it 'does nothing if the one-shot recovery job is executed before the deadline' do
    allow(turn).to receive(:deadline_at).and_return(1.minute.from_now)

    described_class.perform_now(42)

    expect(ChatRing::OutboundCommitDispatcher).not_to have_received(:call)
    expect(ChatRing::Brain::FailureFinalizer).not_to have_received(:call)
  end
end
