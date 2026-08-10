require 'rails_helper'

RSpec.describe 'ChatRing Assistant administration API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:workspace) { account.chat_ring_workspace }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring" }

  it 'creates an account-owned Assistant with one editable draft and fixed supported model' do
    post "#{base_path}/assistants",
         params: { assistant: { name: 'Website Sales' } },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include('name' => 'Website Sales', 'state' => 'draft')
    expect(response.parsed_body['draft']).to include(
      'llm_provider' => 'openai',
      'llm_model' => 'gpt-5.4',
      'handoff_policy' => {
        'on_insufficient_evidence' => 'handoff',
        'on_provider_failure' => 'handoff'
      }
    )
    expect(workspace.assistants.count).to eq(1)
    expect(workspace.assistants.first.configuration_draft).to be_present
  end

  it 'updates the draft with optimistic locking and rejects a stale editor' do
    assistant = create_assistant
    draft = assistant.configuration_draft
    payload = {
      draft: {
        lock_version: draft.lock_version,
        identity: { name: 'Sales specialist' },
        goals: ['Qualify the visitor'],
        instructions: 'Use the Business Knowledge Base.',
        response_guidelines: ['Be concise'],
        guardrails: ['Never invent pricing'],
        handoff_policy: { on_insufficient_evidence: 'handoff', on_provider_failure: 'abstain' }
      }
    }

    patch "#{base_path}/assistants/#{assistant.id}/update_draft", params: payload, headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('draft', 'instructions')).to eq('Use the Business Knowledge Base.')

    patch "#{base_path}/assistants/#{assistant.id}/update_draft", params: payload, headers: admin.create_new_auth_token

    expect(response).to have_http_status(:conflict)
  end

  it 'rejects a malformed draft revision without mutating configuration' do
    assistant = create_assistant
    original_instructions = assistant.configuration_draft.instructions

    patch "#{base_path}/assistants/#{assistant.id}/update_draft",
          params: { draft: { lock_version: 'current', instructions: 'must not persist' } },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:bad_request)
    expect(assistant.configuration_draft.reload.instructions).to eq(original_instructions)
  end

  it 'publishes immutable versions and provisions one native managed AgentBot' do
    assistant = create_assistant
    draft = assistant.configuration_draft

    post "#{base_path}/assistants/#{assistant.id}/publish",
         params: { lock_version: draft.lock_version },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('assistant' => hash_including('state' => 'published_unbound'))
    version = assistant.reload.current_version
    expect(version).to have_attributes(version: 1, llm_provider: 'openai', llm_model: 'gpt-5.4')
    expect(version.update(instructions: 'mutated')).to be(false)
    expect(assistant.agent_bot_connection.agent_bot).to have_attributes(
      account_id: account.id,
      outgoing_url: nil,
      bot_type: 'chatring_assistant'
    )
  end

  it 'returns the same immutable version when the same unchanged draft revision is published again' do
    assistant = create_assistant

    post "#{base_path}/assistants/#{assistant.id}/publish",
         params: { lock_version: assistant.configuration_draft.lock_version },
         headers: admin.create_new_auth_token
    first_version_id = response.parsed_body.dig('version', 'id')
    published_lock_version = response.parsed_body.dig('assistant', 'draft', 'lock_version')

    post "#{base_path}/assistants/#{assistant.id}/publish",
         params: { lock_version: published_lock_version },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('version', 'id')).to eq(first_version_id)
    expect(assistant.versions.count).to eq(1)
  end

  it 'preflights, binds and disables through the existing native Inbox services' do
    assistant = published_assistant
    inbox = create(:inbox, account: account)

    get "#{base_path}/assistants/#{assistant.id}/binding_preflight",
        params: { inbox_id: inbox.id },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('ready' => true, 'conflicts' => [])

    post "#{base_path}/assistants/#{assistant.id}/bind",
         params: { inbox_id: inbox.id },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:created)
    binding = assistant.inbox_bindings.active.find_by!(chatwoot_inbox_id: inbox.id)
    expect(inbox.reload.agent_bot).to eq(assistant.agent_bot_connection.agent_bot)

    delete "#{base_path}/assistant_bindings/#{binding.id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:no_content)
    expect(binding.reload).to be_inactive
    expect(inbox.reload.agent_bot).to be_nil
  end

  it 'rotates the native managed AgentBot secret without returning it' do
    assistant = published_assistant
    original_secret = assistant.agent_bot_connection.agent_bot.secret

    post "#{base_path}/assistants/#{assistant.id}/rotate_managed_secret", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('rotated' => true)
    expect(response.body).not_to include(original_secret)
    expect(assistant.agent_bot_connection.agent_bot.reload.secret).not_to eq(original_secret)
  end

  it 'archives by draining native bindings and preserves archived state as terminal' do
    assistant = published_assistant
    inbox = create(:inbox, account: account)
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call

    post "#{base_path}/assistants/#{assistant.id}/archive", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['state']).to eq('archived')
    expect(assistant.reload).to be_archived
    expect(assistant.inbox_bindings.active).to be_empty
    expect(inbox.reload.agent_bot).to be_nil
  end

  it 'keeps an archived Assistant read-only across every routine mutation endpoint' do
    assistant = published_assistant
    ChatRing::AssistantProvisioning::AssistantArchiver.new(assistant: assistant).call
    original_draft = assistant.configuration_draft.reload.attributes
    inbox = create(:inbox, account: account)

    patch "#{base_path}/assistants/#{assistant.id}/update_draft",
          params: { draft: { lock_version: assistant.configuration_draft.lock_version, instructions: 'mutated' } },
          headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    post "#{base_path}/assistants/#{assistant.id}/bind",
         params: { inbox_id: inbox.id },
         headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    post "#{base_path}/assistants/#{assistant.id}/rotate_managed_secret", headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    post "#{base_path}/assistants/#{assistant.id}/publish",
         params: { lock_version: assistant.configuration_draft.lock_version },
         headers: admin.create_new_auth_token
    expect(response).to have_http_status(:unprocessable_entity)

    expect(assistant.configuration_draft.reload.attributes).to eq(original_draft)
    expect(inbox.reload.agent_bot).to be_nil
  end

  it 'reports the native drain impact before switching Assistants' do
    original = published_assistant
    replacement = published_assistant(name: 'Replacement Sales')
    inbox = create(:inbox, account: account)
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: original, inbox: inbox).call
    create(:conversation, account: account, inbox: inbox, assignee_agent_bot: original.agent_bot_connection.agent_bot, status: :pending)

    get "#{base_path}/assistants/#{replacement.id}/binding_preflight",
        params: { inbox_id: inbox.id },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('ready' => true)
    expect(response.parsed_body['impact']).to include(
      'pending_conversations' => 1,
      'non_pending_conversations' => 0,
      'nonterminal_turns' => 0
    )
  end

  it 'enforces administrator access and account ownership' do
    assistant = create_assistant
    other_account = create(:account)
    other_admin = create(:user, account: other_account, role: :administrator)

    get "#{base_path}/assistants", headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/accounts/#{other_account.id}/chat_ring/assistants/#{assistant.id}", headers: other_admin.create_new_auth_token
    expect(response).to have_http_status(:not_found)
  end

  def create_assistant(name: 'Website Sales')
    assistant = workspace.assistants.create!(name: name)
    assistant.create_configuration_draft!(
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
      handoff_policy: {
        'on_insufficient_evidence' => 'handoff',
        'on_provider_failure' => 'handoff'
      }
    )
    assistant
  end

  def published_assistant(name: 'Website Sales')
    assistant = create_assistant(name: name)
    ChatRing::AssistantManagement::Publisher.new(
      assistant: assistant,
      expected_lock_version: assistant.configuration_draft.lock_version
    ).call
    assistant.reload
  end
end
