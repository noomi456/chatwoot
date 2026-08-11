require 'rails_helper'

RSpec.describe ChatRing::Tools::OutcomePreparer do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Website Sales') }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:assistant_version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { tool_grants: [{ 'key' => 'request_appointment', 'version' => 1 }] }
    ).call
  end
  let(:connection) do
    assistant_version
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
  end
  let(:binding) do
    connection
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, status: :pending, assignee_agent_bot: connection.agent_bot)
  end
  let(:trigger_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, private: false, content: 'Can I book a demo?')
  end
  let(:turn) do
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: conversation,
      trigger_message: trigger_message,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: assistant_version,
      expected_agent_bot: connection.agent_bot,
      status: :running,
      started_at: Time.current,
      native_handling_snapshot: { 'automation' => { 'completed' => true, 'effects' => [] } },
      deadline_at: 2.minutes.from_now
    )
  end
  let(:decision) do
    ChatRing::Brain::Decision.from_payload(
      {
        'decision_type' => 'request_appointment',
        'response_text' => '',
        'reason_code' => 'visitor_requested_demo',
        'evidence_ids' => [],
        'tool_request' => {
          'key' => 'request_appointment',
          'version' => 1,
          'arguments' => { 'requested_time_window' => 'next week', 'reason_code' => 'visitor_requested_demo' }
        }
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence'
    )
  end
  let(:policy_actor) { create(:user, account: account, role: :administrator) }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: policy_actor,
      expected_lock_version: 0,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly',
          'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link',
          'link_label' => 'Book a 30 minute demo'
        }
      }
    ).call
  end

  it 'pins authorization without creating a customer Message, then commits through the native Message path exactly once' do
    turn

    expect { described_class.call(turn, decision) }.not_to change(Message, :count)

    expect(turn.outbound_commit).to have_attributes(status: 'pending', outcome_type: 'tool')
    expect(turn.tool_execution).to have_attributes(
      status: 'pending',
      tool_key: 'request_appointment',
      tool_version: 1,
      authorization_result: 'authorized',
      renderer: 'approved_link',
      validated_arguments: {
        'requested_time_window' => 'next week',
        'reason_code' => 'visitor_requested_demo'
      }
    )

    2.times { ChatRing::OutboundCommitJob.perform_now(turn.id) }

    message = conversation.messages.outgoing.find_by!(sender: connection.agent_bot)
    expect(message).to have_attributes(
      content: "Book a 30 minute demo\nhttps://calendly.com/cqalerts3/30min",
      content_type: 'text'
    )
    expect(turn.reload).to be_status_committed
    expect(turn.outbound_commit.reload).to have_attributes(status: 'committed', chatwoot_message_id: message.id)
    expect(turn.tool_execution.reload).to have_attributes(status: 'committed', failure_code: nil)
  end

  it 'adds only the pinned server-owned Calendly presentation to the ordinary native Message' do
    policy = ChatRing::InboxToolPolicy.find_by!(chatwoot_inbox_id: inbox.id)
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: policy_actor,
      expected_lock_version: policy.lock_version,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly',
          'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link',
          'link_label' => 'Book a 30 minute demo',
          'website_presentation' => 'calendar_embed'
        }
      }
    ).call

    described_class.call(turn, decision)
    2.times { ChatRing::OutboundCommitJob.perform_now(turn.id) }

    message = turn.reload.outbound_commit.message
    expect(message.content).to eq("Book a 30 minute demo\nhttps://calendly.com/cqalerts3/30min")
    expect(message.content_attributes.fetch('chatring_tool')).to eq(
      'presentation_mode' => 'calendar_embed',
      'provider' => 'calendly',
      'approved_url' => 'https://calendly.com/cqalerts3/30min',
      'link_label' => 'Book a 30 minute demo'
    )
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot).count).to eq(1)
  end

  it 'rejects the pending Tool outcome when native human takeover wins before commit' do
    described_class.call(turn, decision)
    conversation.bot_handoff!

    expect { ChatRing::OutboundCommitJob.perform_now(turn.id) }.not_to change(Message, :count)

    expect(turn.reload).to be_status_cancelled
    expect(turn.failure_code).to eq('conversation_not_pending')
    expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'conversation_not_pending')
    expect(turn.tool_execution.reload).to have_attributes(status: 'rejected', failure_code: 'conversation_not_pending')
  end

  it 'rejects the pending Tool outcome when the Inbox policy is disabled before native commit' do
    described_class.call(turn, decision)
    ChatRing::InboxToolPolicy.find_by!(chatwoot_inbox_id: inbox.id).update!(status: :disabled)

    expect { ChatRing::OutboundCommitJob.perform_now(turn.id) }.not_to change(Message, :count)

    expect(turn.reload).to have_attributes(status: 'cancelled', failure_code: 'tool_policy_inactive')
    expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'tool_policy_inactive')
    expect(turn.tool_execution.reload).to have_attributes(status: 'rejected', failure_code: 'tool_policy_inactive')
  end

  it 'rejects the pinned Tool outcome when a newer Inbox policy version wins before native commit' do
    described_class.call(turn, decision)
    policy = ChatRing::InboxToolPolicy.find_by!(chatwoot_inbox_id: inbox.id)
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: policy_actor,
      expected_lock_version: policy.lock_version,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly',
          'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link',
          'link_label' => 'Book another demo'
        }
      }
    ).call

    expect { ChatRing::OutboundCommitJob.perform_now(turn.id) }.not_to change(Message, :count)

    expect(turn.reload).to have_attributes(status: 'cancelled', failure_code: 'tool_policy_changed')
    expect(turn.tool_execution.reload).to have_attributes(status: 'rejected', failure_code: 'tool_policy_changed')
  end
end
