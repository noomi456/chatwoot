require 'rails_helper'

RSpec.describe ChatRing::Brain::VisitorCitationPresenter do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:trigger_message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, content: 'What plans do you offer?')
  end
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Sales') }
  let(:version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true)
    ).call
  end
  let(:connection) do
    version
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
  end
  let(:binding) do
    connection
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end
  let(:turn) do
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: conversation,
      trigger_message: trigger_message,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: version,
      expected_agent_bot: connection.agent_bot,
      status: :ready_to_commit,
      deadline_at: 2.minutes.from_now,
      decision_type: 'reply',
      decision_payload: {
        'decision_type' => 'reply',
        'response_text' => 'Our pricing starts at $49.',
        'reason_code' => 'answered',
        'evidence_ids' => %w[public private duplicate]
      }
    )
  end

  it 'projects only deduplicated public source links without internal evidence data' do
    create_evidence('public', position: 0, title: 'Pricing', url: 'https://chatring.ai/pricing', heading_path: ['Plans'])
    create_evidence('private', position: 1, title: 'Internal pricing', url: nil)
    create_evidence('duplicate', position: 2, title: 'Pricing', url: 'https://chatring.ai/pricing')

    expect(described_class.call(turn)).to eq(
      [{ 'title' => 'Pricing', 'url' => 'https://chatring.ai/pricing', 'heading_path' => ['Plans'] }]
    )
  end

  it 'rejects unsafe URLs even when they are present in persisted evidence' do
    create_evidence('public', position: 0, title: 'Private host', url: 'http://127.0.0.1/admin')

    expect(described_class.call(turn)).to be_empty
  end

  private

  def create_evidence(evidence_id, position:, title:, url:, heading_path: [])
    turn.evidence.create!(
      position: position,
      evidence_id: evidence_id,
      source_kind: 'website',
      source_reference: url || "file:#{evidence_id}",
      source_title: title,
      public_url: url,
      heading_path: heading_path,
      excerpt: 'Evidence excerpt that must not reach the Widget citation payload.',
      source_content_hash: Digest::SHA256.hexdigest(evidence_id),
      rank: position,
      score: 0.9,
      metadata: { 'private_marker' => 'must-not-leak' }
    )
  end
end
