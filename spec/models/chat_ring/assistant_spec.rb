require 'rails_helper'

RSpec.describe ChatRing::Assistant do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }

  it 'requires a unique name within the Workspace' do
    create_assistant = -> { described_class.create!(workspace: workspace, name: 'Support') }

    expect { 2.times { create_assistant.call } }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'requires a current version before activation' do
    assistant = described_class.new(workspace: workspace, name: 'Support', status: :active)

    expect(assistant).not_to be_valid
    expect(assistant.errors[:current_version]).to include('is required for an active Assistant')
  end
end
