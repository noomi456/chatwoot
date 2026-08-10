require 'rails_helper'

RSpec.describe ChatRing::AiTurnDispatcher do
  let(:turn) { instance_double(ChatRing::AiTurn, id: 42, deadline_at: 1.minute.from_now) }
  let(:primary_job) { instance_double(ActiveJob::Base, successfully_enqueued?: false) }
  let(:recovery_job) { instance_double(ActiveJob::Base, successfully_enqueued?: true) }
  let(:configured_job) { instance_double(ActiveJob::ConfiguredJob) }

  it 'records that the one-shot recovery accepted work when the primary queue rejects it' do
    allow(ChatRing::AiTurnJob).to receive(:perform_later).with(42).and_return(primary_job)
    allow(ChatRing::AiTurnRecoveryJob).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later).with(42).and_return(recovery_job)

    result = described_class.call(turn)

    expect(result).to have_attributes(primary_enqueued: false, recovery_enqueued: true)
    expect(ChatRing::AiTurnRecoveryJob).to have_received(:set).with(wait_until: turn.deadline_at + 15.seconds)
  end

  it 'still schedules recovery when the primary enqueue raises ambiguously' do
    allow(ChatRing::AiTurnJob).to receive(:perform_later).with(42).and_raise(ActiveJob::EnqueueError)
    allow(ChatRing::AiTurnRecoveryJob).to receive(:set).and_return(configured_job)
    allow(configured_job).to receive(:perform_later).with(42).and_return(recovery_job)

    result = described_class.call(turn)

    expect(result).to have_attributes(primary_enqueued: false, recovery_enqueued: true)
  end
end
