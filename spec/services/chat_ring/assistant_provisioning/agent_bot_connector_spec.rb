require 'rails_helper'

RSpec.describe ChatRing::AssistantProvisioning::AgentBotConnector do
  subject(:connect) { described_class.new(workspace: workspace, inbox: inbox, agent_bot: agent_bot).call }

  let(:account) { create(:account) }
  let(:workspace) { ChatRing::Workspace.for_account!(account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account) }

  it 'connects an account-owned AgentBot under the inbox lock' do
    expect(inbox).to receive(:with_lock).and_call_original

    connection = connect

    expect(connection).to be_active
    expect(connection.account).to eq(account)
    expect(connection.agent_bot).to eq(agent_bot)
    expect(connection.inbox).to eq(inbox)
  end

  it 'reactivates the expected existing connection' do
    existing = create(:agent_bot_inbox, account: account, inbox: inbox, agent_bot: agent_bot, status: :inactive)

    expect(connect).to eq(existing)
    expect(existing.reload).to be_active
  end

  it 'rejects a system AgentBot' do
    agent_bot.update!(account: nil)

    expect { connect }.to raise_error(described_class::OwnershipError, 'AgentBot must be account-owned')
  end

  it 'rejects an AgentBot from another account' do
    agent_bot.update!(account: create(:account))

    expect { connect }.to raise_error(described_class::OwnershipError, 'AgentBot must belong to the workspace account')
  end

  it 'rejects an inbox from another account' do
    other_inbox = create(:inbox, account: create(:account))
    connector = described_class.new(workspace: workspace, inbox: other_inbox, agent_bot: agent_bot)

    expect { connector.call }.to raise_error(described_class::OwnershipError, 'inbox must belong to the workspace account')
  end

  it 'rejects provisioning for a suspended workspace' do
    workspace.update!(status: 'suspended')

    expect { connect }.to raise_error(described_class::OwnershipError, 'workspace must be active')
  end

  it 'fails closed when another responder is configured' do
    conflicting_bot = create(:agent_bot, account: account)
    create(:agent_bot_inbox, account: account, inbox: inbox, agent_bot: conflicting_bot)

    expect { connect }.to raise_error(described_class::ConflictError) do |error|
      expect(error.conflicts.map(&:kind)).to eq([:agent_bot])
    end
  end
end
