require 'rails_helper'

RSpec.describe ChatRing::OutboundCommitDispatcher do
  let(:turn) { instance_double(ChatRing::AiTurn, id: 42, status_ready_to_commit?: true) }
  let(:job) { instance_double(ChatRing::OutboundCommitJob, successfully_enqueued?: true) }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    allow(ChatRing::AiTurn).to receive(:find_by).with(id: 42).and_return(turn)
    allow(ChatRing::OutboundCommitJob).to receive(:perform_now)
  end

  it 'uses the ordinary outbound job when the queue accepts it' do
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).with(42).and_return(job)

    expect(described_class.call(42)).to eq(:enqueued)
    expect(ChatRing::OutboundCommitJob).not_to have_received(:perform_now)
  end

  it 'uses the same idempotent job inline when enqueue is rejected' do
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).with(42).and_return(false)
    allow(ChatRing::OutboundCommitJob).to receive(:perform_now).with(42)

    expect(described_class.call(42)).to eq(:performed_inline)
    expect(ChatRing::OutboundCommitJob).to have_received(:perform_now).once
  end

  it 'uses the same idempotent job inline after an ambiguous enqueue exception' do
    allow(ChatRing::OutboundCommitJob).to receive(:perform_later).with(42).and_raise(ActiveJob::EnqueueError)
    allow(ChatRing::OutboundCommitJob).to receive(:perform_now).with(42)

    expect(described_class.call(42)).to eq(:performed_inline)
    expect(ChatRing::OutboundCommitJob).to have_received(:perform_now).once
  end

  it 'does nothing while the public response gate is closed' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)

    expect(described_class.call(42)).to eq(:gate_closed)
    expect(ChatRing::AiTurn).not_to have_received(:find_by)
  end
end
