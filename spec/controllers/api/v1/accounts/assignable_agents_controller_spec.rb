require 'rails_helper'

RSpec.describe 'Assignable Agents API', type: :request do
  let(:account) { create(:account) }
  let(:agent1) { create(:user, account: account, role: :agent) }
  let!(:agent2) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }

  describe 'GET /api/v1/accounts/{account.id}/assignable_agents' do
    let(:inbox1) { create(:inbox, account: account) }
    let(:inbox2) { create(:inbox, account: account) }

    before do
      create(:inbox_member, user: agent1, inbox: inbox1)
      create(:inbox_member, user: agent1, inbox: inbox2)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/assignable_agents"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the user is not part of an inbox' do
      context 'when the user is an admininstrator' do
        it 'returns all assignable inbox members along with administrators' do
          get "/api/v1/accounts/#{account.id}/assignable_agents",
              params: { inbox_ids: [inbox1.id, inbox2.id] },
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
          response_data = JSON.parse(response.body, symbolize_names: true)[:payload]
          expect(response_data.size).to eq(2)
          expect(response_data.pluck(:role)).to include('agent', 'administrator')
        end
      end

      context 'when the user is an agent' do
        it 'returns unauthorized' do
          get "/api/v1/accounts/#{account.id}/assignable_agents",
              params: { inbox_ids: [inbox1.id, inbox2.id] },
              headers: agent2.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    context 'when the user is part of the inbox' do
      it 'returns all assignable inbox members along with administrators' do
        get "/api/v1/accounts/#{account.id}/assignable_agents",
            params: { inbox_ids: [inbox1.id, inbox2.id] },
            headers: agent1.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)[:payload]
        expect(response_data.size).to eq(2)
        expect(response_data.pluck(:role)).to include('agent', 'administrator')
      end

      context 'with Agent Bots' do
        let!(:account_bot) { create(:agent_bot, account: account, name: 'Account bot') }
        let!(:global_bot) { create(:agent_bot, account: nil, name: 'Global bot') }

        it 'returns assignable agents and accessible agent bots' do
          get "/api/v1/accounts/#{account.id}/assignable_agents",
              params: { inbox_ids: [inbox1.id, inbox2.id], include_agent_bots: true },
              headers: agent1.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)

          response_data = response.parsed_body['payload']
          expect(response_data.pluck('assignee_type')).to include('User', 'AgentBot')
          expect(response_data.pluck('name')).to include(agent1.name, admin.name, account_bot.name, global_bot.name)
        end

        it 'hides managed Assistant bots unless the same active bot is connected to every selected Inbox' do
          workspace = account.chat_ring_workspace
          assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
          ChatRing::AssistantVersions::Publisher.new(
            assistant: assistant,
            knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
            configuration: { instructions: 'Answer from evidence.' }
          ).call
          connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
          ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox1).call

          get "/api/v1/accounts/#{account.id}/assignable_agents",
              params: { inbox_ids: [inbox1.id, inbox2.id], include_agent_bots: true },
              headers: agent1.create_new_auth_token,
              as: :json

          expect(response.parsed_body['payload'].pluck('id')).not_to include(connection.agent_bot_id)

          ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox2).call
          get "/api/v1/accounts/#{account.id}/assignable_agents",
              params: { inbox_ids: [inbox1.id, inbox2.id], include_agent_bots: true },
              headers: agent1.create_new_auth_token,
              as: :json

          expect(response.parsed_body['payload'].pluck('id')).to include(connection.agent_bot_id)
        end
      end
    end
  end
end
