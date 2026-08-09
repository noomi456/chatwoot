require 'rails_helper'

RSpec.describe 'ChatRing Assistant automation conflicts', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Website Assistant') }

  before do
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { instructions: 'Answer from evidence.' }
    ).call
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end

  it 'rejects creation of a potentially matching public-response automation' do
    expect do
      post "/api/v1/accounts/#{account.id}/automation_rules",
           headers: administrator.create_new_auth_token,
           params: automation_params('send_message')
    end.not_to change(AutomationRule, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'allows non-responder automation for the bound Inbox' do
    expect do
      post "/api/v1/accounts/#{account.id}/automation_rules",
           headers: administrator.create_new_auth_token,
           params: automation_params('add_label')
    end.to change(AutomationRule, :count).by(1)

    expect(response).to have_http_status(:success)
  end

  private

  def automation_params(action_name)
    {
      name: 'Widget automation',
      event_name: 'message_created',
      active: true,
      conditions: [{
        attribute_key: 'inbox_id',
        filter_operator: 'equal_to',
        values: [inbox.id],
        query_operator: nil
      }],
      actions: [{ action_name: action_name, action_params: ['value'] }]
    }
  end
end
