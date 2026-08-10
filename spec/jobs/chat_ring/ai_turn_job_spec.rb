require 'rails_helper'

RSpec.describe ChatRing::AiTurnJob do
  let(:turn) { instance_double(ChatRing::AiTurn, id: 42) }
  let(:runner) { instance_double(ChatRing::Brain::Runner, call: nil) }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    allow(ChatRing::AiTurn).to receive(:find_by).with(id: 42).and_return(turn)
    allow(ChatRing::Brain::Runner).to receive(:new).with(turn).and_return(runner)
    allow(ChatRing::OutboundCommitDispatcher).to receive(:call).with(42)
  end

  it 'dispatches the durable outcome after one Brain execution attempt' do
    described_class.perform_now(42)

    expect(runner).to have_received(:call).once
    expect(ChatRing::OutboundCommitDispatcher).to have_received(:call).with(42).once
  end
end
