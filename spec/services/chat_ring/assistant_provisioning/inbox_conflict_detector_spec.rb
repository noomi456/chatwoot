require 'rails_helper'

RSpec.describe ChatRing::AssistantProvisioning::InboxConflictDetector do
  subject(:conflicts) { detector.call }

  let(:inbox) { create(:inbox) }
  let(:expected_agent_bot_id) { nil }
  let(:detector) { described_class.new(inbox: inbox, expected_agent_bot_id: expected_agent_bot_id) }

  before do
    allow(detector).to receive(:captain_inbox_id).and_return(nil)
  end

  it 'returns no conflict for an unconfigured inbox' do
    expect(conflicts).to be_empty
  end

  it 'reports an active AgentBot connection' do
    connection = create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: inbox.account))

    expect(conflicts.map(&:kind)).to eq([:agent_bot])
    expect(conflicts.first.record_id).to eq(connection.id)
  end

  it 'allows the expected AgentBot connection' do
    connection = create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: inbox.account))
    detector = described_class.new(inbox: inbox, expected_agent_bot_id: connection.agent_bot_id)
    allow(detector).to receive(:captain_inbox_id).and_return(nil)

    expect(detector.call).to be_empty
  end

  it 'ignores an inactive AgentBot connection' do
    create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: inbox.account), status: :inactive)

    expect(conflicts).to be_empty
  end

  it 'reports an enabled Dialogflow hook' do
    hook = create(:integrations_hook, :dialogflow, account: inbox.account, inbox: inbox)

    expect(conflicts.map(&:kind)).to eq([:dialogflow])
    expect(conflicts.first.record_id).to eq(hook.id)
  end

  it 'ignores a disabled Dialogflow hook' do
    create(:integrations_hook, :dialogflow, account: inbox.account, inbox: inbox, status: :disabled)

    expect(conflicts).to be_empty
  end

  it 'reports a Captain association without loading Captain models' do
    allow(detector).to receive(:captain_inbox_id).and_return(123)

    expect(conflicts.map(&:kind)).to eq([:captain])
    expect(conflicts.first.record_id).to eq(123)
  end
end
