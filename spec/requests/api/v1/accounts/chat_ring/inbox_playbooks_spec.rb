require 'rails_helper'

RSpec.describe 'ChatRing Inbox Playbooks API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/inbox_playbooks" }
  let(:definition) do
    {
      trigger_phrases: ['pricing options'],
      entry_step_id: 'ask_need',
      collected_fields: [{ key: 'need', type: 'string', required: true, native_contact_attribute_key: nil }],
      tool_allowlist: [],
      steps: [
        { id: 'ask_need', kind: 'ask_text', prompt: 'What do you need?', field_key: 'need', next_step_id: 'complete' },
        { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you. Your request is complete.' }
      ],
      safety_rules: {
        on_human_request: 'native_availability',
        on_side_question: 'answer_then_resume'
      }
    }
  end

  it 'creates, validates, saves, and publishes an Inbox-owned Playbook without changing conversation state' do # rubocop:disable RSpec/MultipleExpectations
    expect do
      post base_path,
           params: { playbook: { inbox_id: inbox.id, name: 'Pricing discovery', purpose: 'Qualify pricing interest.' } },
           headers: admin.create_new_auth_token,
           as: :json
    end.not_to(change { [Conversation.count, Message.count, ChatRing::AiTurn.count] })

    expect(response).to have_http_status(:created), response.body
    playbook = ChatRing::InboxPlaybook.find(response.parsed_body.fetch('id'))

    patch "#{base_path}/#{playbook.id}/update_draft",
          params: {
            playbook: {
              lock_version: playbook.lock_version,
              name: playbook.name,
              purpose: playbook.purpose,
              definition: definition
            }
          },
          headers: admin.create_new_auth_token,
          as: :json
    expect(response).to have_http_status(:ok), response.body

    post "#{base_path}/#{playbook.id}/validate",
         params: { definition: definition },
         headers: admin.create_new_auth_token,
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include('valid' => true, 'errors' => [])

    post "#{base_path}/#{playbook.id}/publish",
         params: { lock_version: playbook.reload.lock_version },
         headers: admin.create_new_auth_token,
         as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig('playbook', 'status')).to eq('active')
    expect(response.parsed_body.dig('version', 'definition', 'trigger_phrases')).to eq(['pricing options'])
    expect([Conversation.count, Message.count, ChatRing::AiTurn.count]).to eq([0, 0, 0])
  end

  it 'keeps Playbooks scoped to the native account and Inbox' do
    foreign_inbox = create(:inbox)

    post base_path,
         params: { playbook: { inbox_id: foreign_inbox.id, name: 'Foreign', purpose: '' } },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:not_found), response.body
    expect(ChatRing::InboxPlaybook.count).to eq(0)
  end

  it 'restricts Playbook administration to account administrators' do
    get base_path, headers: agent.create_new_auth_token

    expect(response).to have_http_status(:unauthorized), response.body
  end

  it 'rejects a stale draft write' do
    playbook = account.chat_ring_workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: admin,
      name: 'Pricing discovery',
      purpose: '',
      draft_definition: definition
    )
    playbook.update!(purpose: 'Changed elsewhere')

    patch "#{base_path}/#{playbook.id}/update_draft",
          params: {
            playbook: {
              lock_version: 0,
              name: playbook.name,
              purpose: 'Stale change',
              definition: definition
            }
          },
          headers: admin.create_new_auth_token,
          as: :json

    expect(response).to have_http_status(:conflict), response.body
    expect(response.parsed_body.fetch('code')).to eq('stale_playbook')
  end
end
