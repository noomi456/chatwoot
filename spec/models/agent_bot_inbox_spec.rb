require 'rails_helper'

RSpec.describe AgentBotInbox do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:inbox_id) }
    it { is_expected.to validate_presence_of(:agent_bot_id) }

    it 'allows only one AgentBot connection per inbox' do
      existing = create(:agent_bot_inbox)
      duplicate = build(:agent_bot_inbox, inbox: existing.inbox, agent_bot: create(:agent_bot, account: existing.account))

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:inbox_id]).to include('has already been taken')
    end

    it 'uses the inbox account' do
      inbox = create(:inbox)
      connection = build(:agent_bot_inbox, inbox: inbox, account: create(:account))

      connection.validate

      expect(connection.account).to eq(inbox.account)
    end

    it 'rejects an account-owned AgentBot from another account' do
      inbox = create(:inbox)
      foreign_bot = create(:agent_bot, account: create(:account))
      connection = build(:agent_bot_inbox, inbox: inbox, agent_bot: foreign_bot)

      expect(connection).not_to be_valid
      expect(connection.errors[:agent_bot]).to include('must belong to the inbox account')
    end

    it 'continues to support system AgentBots for existing Chatwoot integrations' do
      inbox = create(:inbox)
      connection = build(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot, account: nil))

      expect(connection).to be_valid
    end
  end

  describe 'associations' do
    it { is_expected.to belong_to(:agent_bot) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to belong_to(:account) }
  end
end
