require 'rails_helper'

RSpec.describe ChatRing::Tools::PolicyPublisher do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:configuration) do
    {
      request_appointment: {
        provider: 'calendly',
        url: 'https://calendly.com/chatring/demo',
        fallback_mode: 'approved_link',
        link_label: 'Book a meeting'
      }
    }
  end

  it 'publishes immutable, monotonically versioned Inbox policy snapshots' do
    first = publish(expected_lock_version: 0)
    second = publish(expected_lock_version: first.inbox_tool_policy.reload.lock_version)

    expect([first.version, second.version]).to eq([1, 2])
    expect(first.update(tool_configurations: {})).to be(false)
    expect(second.inbox_tool_policy.current_version).to eq(second)
  end

  it 'rejects stale writers without creating another version' do
    publish(expected_lock_version: 0)

    expect { publish(expected_lock_version: 0) }.to raise_error(described_class::InvalidRevision)
    expect(ChatRing::InboxToolPolicyVersion.count).to eq(1)
  end

  it 'rejects cross-account Inbox configuration' do
    foreign_inbox = create(:inbox)

    expect do
      described_class.new(
        workspace: workspace,
        inbox: foreign_inbox,
        actor: actor,
        expected_lock_version: 0,
        enabled_tools: [{ key: 'request_appointment', version: 1 }],
        tool_configurations: configuration
      ).call
    end.to raise_error(ActiveRecord::RecordNotFound)
  end

  private

  def publish(expected_lock_version:)
    described_class.new(
      workspace: workspace,
      inbox: inbox,
      actor: actor,
      expected_lock_version: expected_lock_version,
      enabled_tools: [{ key: 'request_appointment', version: 1 }],
      tool_configurations: configuration
    ).call
  end
end
