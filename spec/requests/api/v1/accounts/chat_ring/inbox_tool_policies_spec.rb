require 'rails_helper'

RSpec.describe 'ChatRing Inbox Tool policies API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/inbox_tool_policies" }

  it 'publishes one account-owned Inbox policy and returns its renderer capability' do
    patch "#{base_path}/#{inbox.id}",
          params: {
            tool_policy: {
              lock_version: 0,
              enabled_tools: [{ key: 'request_appointment', version: 1 }],
              tool_configurations: {
                request_appointment: {
                  provider: 'calendly',
                  url: 'https://calendly.com/chatring/demo',
                  fallback_mode: 'approved_link',
                  link_label: 'Book a meeting',
                  website_presentation: 'calendar_embed'
                }
              }
            }
          },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig('current_version', 'version')).to eq(1)
    expect(response.parsed_body.fetch('capabilities')).to include(
      'key' => 'request_appointment',
      'version' => 1,
      'available' => true,
      'renderer' => 'calendar_embed',
      'fallback' => 'approved_link',
      'reason' => nil
    )
  end

  it 'rejects an embed request outside the certified Calendly Website renderer' do
    patch "#{base_path}/#{inbox.id}",
          params: {
            tool_policy: {
              lock_version: 0,
              enabled_tools: [{ key: 'request_appointment', version: 1 }],
              tool_configurations: {
                request_appointment: {
                  provider: 'custom_link',
                  url: 'https://calendar.example.com/demo',
                  fallback_mode: 'approved_link',
                  link_label: 'Book a meeting',
                  website_presentation: 'calendar_embed'
                }
              }
            }
          },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(ChatRing::InboxToolPolicyVersion.count).to eq(0)
  end

  it 'never accepts a private approved calendar URL' do
    patch "#{base_path}/#{inbox.id}",
          params: {
            tool_policy: {
              lock_version: 0,
              enabled_tools: [{ key: 'request_appointment', version: 1 }],
              tool_configurations: {
                request_appointment: {
                  provider: 'custom_link',
                  url: 'https://127.0.0.1/admin',
                  fallback_mode: 'approved_link'
                }
              }
            }
          },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(ChatRing::InboxToolPolicyVersion.count).to eq(0)
  end

  it 'rejects configuration fields outside the code-owned Tool contract' do
    patch "#{base_path}/#{inbox.id}",
          params: {
            tool_policy: {
              lock_version: 0,
              enabled_tools: [{ key: 'request_appointment', version: 1 }],
              tool_configurations: {
                request_appointment: {
                  provider: 'custom_link',
                  url: 'https://calendar.example.com/demo',
                  fallback_mode: 'approved_link',
                  link_label: 'Book a meeting',
                  model_url: 'https://untrusted.example.com'
                }
              }
            }
          },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_entity), response.body
    expect(ChatRing::InboxToolPolicyVersion.count).to eq(0)
  end

  it 'cannot publish a policy for another account Inbox' do
    foreign_inbox = create(:inbox)

    patch "#{base_path}/#{foreign_inbox.id}",
          params: { tool_policy: { lock_version: 0, enabled_tools: [], tool_configurations: {} } },
          headers: admin.create_new_auth_token

    expect(response).to have_http_status(:not_found), response.body
    expect(ChatRing::InboxToolPolicy.count).to eq(0)
  end

  it 'keeps Tool administration restricted to account administrators' do
    get "#{base_path}/definitions", headers: agent.create_new_auth_token

    expect(response).to have_http_status(:unauthorized), response.body
  end
end
