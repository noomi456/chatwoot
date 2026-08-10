require 'rails_helper'

RSpec.describe ChatRing::NativeHandling::AutomationEffectPolicy do
  subject(:terminal_reason) { described_class.terminal_reason(snapshot) }

  let(:before) do
    {
      status: 'pending',
      assignee_id: nil,
      assignee_agent_bot_id: 9,
      team_id: nil,
      priority: nil,
      labels: [],
      automation_public_message_ids: [],
      automation_private_message_ids: []
    }
  end
  let(:after) { before.deep_dup }
  let(:snapshot) { { completed: true, effects: [{ before: before, after: after }] } }

  it 'fails closed when native Automation completion is absent' do
    expect(described_class.terminal_reason({})).to eq('automation_observation_failed')
  end

  it 'fails closed when native effect observation fails' do
    after[:observation_error] = 'ActiveRecord::ConnectionNotEstablished'

    expect(terminal_reason).to eq('automation_observation_failed')
  end

  it 'suppresses AI after an actual public Automation message' do
    after[:automation_public_message_ids] = [41]

    expect(terminal_reason).to eq('native_automation_response')
  end

  it 'suppresses AI after an actual native lifecycle change' do
    after[:team_id] = 12

    expect(terminal_reason).to eq('native_automation_lifecycle_change')
  end

  it 'suppresses AI when lifecycle actions changed state even if the final state returned to its original value' do
    snapshot[:effects].first[:lifecycle_changed] = true

    expect(terminal_reason).to eq('native_automation_lifecycle_change')
  end

  it 'fails closed when action-level lifecycle observation fails' do
    snapshot[:effects].first[:lifecycle_observation_error] = 'ActiveRecord::ConnectionNotEstablished'

    expect(terminal_reason).to eq('automation_observation_failed')
  end

  it 'allows priority, label and private-note effects to coexist' do
    after[:priority] = 'high'
    after[:labels] = ['qualified']
    after[:automation_private_message_ids] = [42]

    expect(terminal_reason).to be_nil
  end
end
