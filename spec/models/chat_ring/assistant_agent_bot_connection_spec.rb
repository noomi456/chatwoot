require 'rails_helper'

RSpec.describe ChatRing::AssistantAgentBotConnection do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }

  it 'rejects system and ordinary webhook AgentBots' do
    connection = described_class.new(
      workspace: workspace,
      assistant: assistant,
      agent_bot: create(:agent_bot, account: nil),
      status: :provisioning
    )

    expect(connection).not_to be_valid
    expect(connection.errors[:agent_bot]).to include('must be account-owned by the Workspace Chatwoot Account')
    expect(connection.errors[:agent_bot]).to include('must be a managed ChatRing Assistant identity')
  end

  it 'requires secret references before becoming active' do
    bot = create(:agent_bot, account: account, bot_type: :chatring_assistant)
    connection = described_class.new(workspace: workspace, assistant: assistant, agent_bot: bot, status: :active)

    expect(connection).not_to be_valid
    expect(connection.errors[:access_token_secret_ref]).to include('is required')
    expect(connection.errors[:webhook_secret_ref]).to include('is required')
  end
end
