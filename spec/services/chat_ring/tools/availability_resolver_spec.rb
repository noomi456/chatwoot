require 'rails_helper'

RSpec.describe ChatRing::Tools::AvailabilityResolver do
  it 'projects only a jointly granted and Inbox-certified Tool without its configured destination' do
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Website Sales')
    version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
      configuration: { tool_grants: [{ 'key' => 'request_appointment', 'version' => 1 }] }
    ).call
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: create(:user, account: account, role: :administrator),
      expected_lock_version: 0,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly',
          'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link',
          'link_label' => 'Book a demo'
        }
      }
    ).call

    available = described_class.new(inbox: inbox, assistant_version: version).call

    expect(available).to contain_exactly(
      include('key' => 'request_appointment', 'version' => 1, 'input_schema' => include('additionalProperties' => false))
    )
    expect(available.to_json).not_to include('calendly.com', 'approved_url', 'link_label')
  end

  it 'intersects Assistant grants with the pinned Playbook step allowlist' do
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Website Sales')
    version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
      configuration: { tool_grants: [{ 'key' => 'request_appointment', 'version' => 1 }] }
    ).call
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: create(:user, account: account, role: :administrator),
      expected_lock_version: 0,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly',
          'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link',
          'link_label' => 'Book a demo'
        }
      }
    ).call

    unavailable = described_class.new(inbox: inbox, assistant_version: version, allowed_tools: []).call
    available = described_class.new(
      inbox: inbox,
      assistant_version: version,
      allowed_tools: [{ 'key' => 'request_appointment', 'version' => 1 }]
    ).call

    expect(unavailable).to be_empty
    expect(available).to contain_exactly(include('key' => 'request_appointment', 'version' => 1))
  end
end
