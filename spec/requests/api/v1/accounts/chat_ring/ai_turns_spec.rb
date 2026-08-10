require 'rails_helper'

RSpec.describe 'ChatRing AI turn inspection API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:workspace) { account.chat_ring_workspace }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/ai_turns" }
  let(:assistant) { workspace.assistants.create!(name: 'Website Sales') }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { llm_provider: 'openai', llm_model: 'gpt-5.4' }
    ).call
  end
  let(:connection) do
    version
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:binding) { ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, assignee_agent_bot: connection.agent_bot, status: :pending)
  end
  let(:message) do
    create(
      :message,
      conversation: conversation,
      account: account,
      inbox: inbox,
      message_type: :incoming,
      content: 'private customer request'
    )
  end

  it 'shows operational failure metadata without customer content, prompts or secrets' do
    turn = failed_turn
    turn.attempts.create!(
      attempt_number: 1,
      provider: 'openai',
      model: 'gpt-5.4',
      status: :failed,
      request_digest: Digest::SHA256.hexdigest('request'),
      failure_code: 'provider_timeout',
      started_at: 1.second.ago,
      completed_at: Time.current
    )

    get "#{base_path}/#{turn.id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'id' => turn.id,
      'status' => 'failed',
      'failure_code' => 'provider_timeout',
      'conversation_id' => turn.chatwoot_conversation_id,
      'trigger_message_id' => turn.trigger_message_id
    )
    expect(response.parsed_body['attempts'].first).to include(
      'provider' => 'openai',
      'model' => 'gpt-5.4',
      'failure_code' => 'provider_timeout'
    )
    expect(response.body).not_to include(turn.trigger_message.content)
    expect(response.parsed_body.keys).not_to include('decision_payload', 'native_handling_snapshot', 'context_metadata')
  end

  it 'prevents cross-account turn inspection' do
    turn = failed_turn
    other_account = create(:account)
    other_admin = create(:user, account: other_account, role: :administrator)

    get "/api/v1/accounts/#{other_account.id}/chat_ring/ai_turns/#{turn.id}", headers: other_admin.create_new_auth_token

    expect(response).to have_http_status(:not_found)
  end

  def failed_turn
    workspace.ai_turns.create!(
      conversation: conversation,
      trigger_message: message,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: version,
      expected_agent_bot: connection.agent_bot,
      status: :failed,
      failure_code: 'provider_timeout',
      decision_payload: {},
      native_handling_snapshot: {},
      deadline_at: 1.minute.ago,
      completed_at: Time.current
    )
  end
end
