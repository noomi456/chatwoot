require 'rails_helper'

RSpec.describe ChatRing::Playbooks::ToolPolicyGuard do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:tool) { { key: 'request_appointment', version: 1 } }
  let(:configuration) do
    {
      request_appointment: {
        provider: 'calendly',
        url: 'https://calendly.com/cqalerts3/30min',
        fallback_mode: 'approved_link',
        link_label: 'Book a 30 minute meeting'
      }
    }
  end

  it 'blocks a Tool policy change that would silently break an active published Playbook' do
    policy_version = ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: actor,
      expected_lock_version: 0,
      enabled_tools: [tool],
      tool_configurations: configuration
    ).call
    playbook = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: 'Book a demo',
      purpose: 'Offer the approved booking path.',
      draft_definition: {
        trigger_phrases: ['book a demo'],
        entry_step_id: 'appointment',
        collected_fields: [],
        tool_allowlist: [tool],
        steps: [
          { id: 'appointment', kind: 'tool', tool: tool, tool_allowlist: [tool] }
        ],
        safety_rules: {
          on_human_request: 'native_availability',
          on_side_question: 'answer_then_resume'
        }
      }
    )
    ChatRing::Playbooks::Publisher.new(playbook: playbook, actor: actor, expected_lock_version: 0).call

    expect do
      ChatRing::Tools::PolicyPublisher.new(
        workspace: workspace,
        inbox: inbox,
        actor: actor,
        expected_lock_version: policy_version.inbox_tool_policy.reload.lock_version,
        enabled_tools: [],
        tool_configurations: {}
      ).call
    end.to raise_error(described_class::InvalidActivePlaybooks, /Book a demo/)
  end
end
