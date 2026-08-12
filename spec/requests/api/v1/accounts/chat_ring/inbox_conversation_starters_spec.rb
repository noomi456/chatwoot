require 'rails_helper'

RSpec.describe 'ChatRing Inbox Conversation Starters API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/inbox_conversation_starters" }
  let(:starters) do
    [
      { label: 'See pricing', prompt: 'What pricing plans do you offer?' },
      { label: 'Book a demo', prompt: 'I would like to book a demo.' }
    ]
  end

  it 'stores one ordered Website Inbox configuration without creating conversation state', :aggregate_failures do
    expect do
      patch "#{base_path}/#{inbox.id}",
            params: { conversation_starters: { lock_version: 0, enabled: true, starters: starters } },
            headers: admin.create_new_auth_token,
            as: :json
    end.to(
      change(ChatRing::InboxConversationStarter, :count).by(1)
        .and(not_change(Conversation, :count))
        .and(not_change(Message, :count))
        .and(not_change(ChatRing::AiTurn, :count))
    )

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body).to include(
      'enabled' => true,
      'lock_version' => 0,
      'starters' => starters.map(&:stringify_keys)
    )
  end

  it 'uses optimistic locking and rejects fields outside the bounded starter contract', :aggregate_failures do
    patch "#{base_path}/#{inbox.id}",
          params: { conversation_starters: { lock_version: 0, enabled: true, starters: starters } },
          headers: admin.create_new_auth_token,
          as: :json
    lock_version = response.parsed_body.fetch('lock_version')

    patch "#{base_path}/#{inbox.id}",
          params: {
            conversation_starters: {
              lock_version: lock_version,
              enabled: true,
              starters: [{ label: 'Unsafe', prompt: 'Hello', destination_url: 'https://example.com' }]
            }
          },
          headers: admin.create_new_auth_token,
          as: :json

    expect(response).to have_http_status(:unprocessable_entity), response.body

    patch "#{base_path}/#{inbox.id}",
          params: { conversation_starters: { lock_version: lock_version, enabled: false, starters: [] } },
          headers: admin.create_new_auth_token,
          as: :json
    expect(response).to have_http_status(:ok), response.body

    patch "#{base_path}/#{inbox.id}",
          params: { conversation_starters: { lock_version: 0, enabled: false, starters: [] } },
          headers: admin.create_new_auth_token,
          as: :json
    expect(response).to have_http_status(:conflict), response.body
  end

  it 'is account-scoped, administrator-only, and Website-Inbox-only', :aggregate_failures do
    foreign_inbox = create(:inbox)
    email_inbox = create(:inbox, account: account, channel: create(:channel_email, account: account))

    patch "#{base_path}/#{foreign_inbox.id}",
          params: { conversation_starters: { lock_version: 0, enabled: true, starters: starters } },
          headers: admin.create_new_auth_token,
          as: :json
    expect(response).to have_http_status(:not_found)

    patch "#{base_path}/#{email_inbox.id}",
          params: { conversation_starters: { lock_version: 0, enabled: true, starters: starters } },
          headers: admin.create_new_auth_token,
          as: :json
    expect(response).to have_http_status(:not_found)

    get base_path, headers: agent.create_new_auth_token
    expect(response).to have_http_status(:unauthorized)
  end
end
