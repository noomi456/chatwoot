require 'rails_helper'

RSpec.describe ChatRing::AutomationConflictClassifier do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  it 'allows directly observed message-created response and lifecycle actions' do
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [{
        'attribute_key' => 'message_type',
        'filter_operator' => 'equal_to',
        'values' => ['incoming'],
        'query_operator' => nil
      }],
      actions: [
        { 'action_name' => 'send_message', 'action_params' => ['Native reply'] },
        { 'action_name' => 'assign_team', 'action_params' => [12] }
      ]
    )

    expect(described_class.rule_conflicts?(rule, inbox)).to be(false)
  end

  it 'blocks message-created response actions that can also match outgoing messages' do
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Native reply'] }]
    )

    expect(described_class.rule_conflicts?(rule, inbox)).to be(true)
  end

  it 'continues to block indirect message-created webhook effects' do
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook'] }]
    )

    expect(described_class.rule_conflicts?(rule, inbox)).to be(true)
  end

  it 'continues to block responder actions on native events outside the completion barrier' do
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'conversation_updated',
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Native reply'] }]
    )

    expect(described_class.rule_conflicts?(rule, inbox)).to be(true)
  end
end
