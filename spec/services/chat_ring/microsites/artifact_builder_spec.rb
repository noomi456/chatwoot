require 'rails_helper'

RSpec.describe ChatRing::Microsites::ArtifactBuilder do
  before do # rubocop:disable RSpec/ScatteredSetup
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:assistant) { workspace.assistants.create!(name: 'Sales') }
  let(:assistant_version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
      configuration: { tool_grants: [{ key: 'request_appointment', version: 1 }] }
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
  let(:trigger) do
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, private: false, content: 'Compare internet plans')
  end
  let(:turn) do
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: conversation,
      trigger_message: trigger,
      inbox_assistant_binding: binding,
      binding_version: binding.binding_version,
      assistant: assistant,
      assistant_version: assistant_version,
      expected_agent_bot: connection.agent_bot,
      status: :ready_to_commit,
      decision_type: 'reply',
      decision_payload: {
        'decision_type' => 'reply',
        'response_text' => 'ChatRing offers verified internet options for different household needs.',
        'reason_code' => 'answered',
        'evidence_ids' => %w[evidence-1 evidence-2],
        'microsite_section_types' => %w[hero features faq]
      },
      native_handling_snapshot: { 'automation' => { 'completed' => true, 'effects' => [] } },
      deadline_at: 2.minutes.from_now
    )
  end

  before do # rubocop:disable RSpec/ScatteredSetup
    turn.evidence.create!(
      position: 0,
      evidence_id: 'evidence-1',
      source_kind: 'website',
      source_reference: 'pricing',
      source_title: 'Internet plans',
      public_url: 'https://chatring.ai/pricing',
      heading_path: ['Internet'],
      excerpt: 'Plans include verified options for light, standard, and heavy household usage.',
      source_content_hash: Digest::SHA256.hexdigest('internet plans'),
      rank: 0,
      score: 0.9,
      metadata: {}
    )
    turn.evidence.create!(
      position: 1,
      evidence_id: 'evidence-2',
      source_kind: 'website',
      source_reference: 'installation',
      source_title: 'Installation',
      public_url: 'https://chatring.ai/installation',
      heading_path: ['Installation'],
      excerpt: 'Installation availability depends on the service address.',
      source_content_hash: Digest::SHA256.hexdigest('installation'),
      rank: 1,
      score: 0.8,
      metadata: {}
    )
  end

  it 'creates one expiring artifact with no more than three normalized grounded sections' do
    artifact = described_class.call(turn)

    expect(artifact).to have_attributes(workspace: workspace, ai_turn: turn, message: nil)
    expect(artifact.source_evidence_ids).to eq(%w[evidence-1 evidence-2])
    expect(artifact.content.fetch('sections').pluck('type')).to eq(%w[hero features_grid faq_accordion])
    expect(artifact.expires_at).to be_within(5.seconds).of(7.days.from_now)
    expect(described_class.call(turn)).to eq(artifact)
  end

  it 'omits requested sections that cannot be populated safely from the selected evidence' do
    turn.update!(
      decision_payload: turn.decision_payload.merge(
        'microsite_section_types' => %w[video_hero interactive_calculator location_map]
      )
    )

    expect(described_class.call(turn)).to be_nil
    expect(turn.reload.microsite_artifact).to be_nil
  end

  it 'uses only the approved appointment Tool configuration for a booking section' do
    actor = create(:user, account: account, role: :administrator)
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: actor,
      expected_lock_version: 0,
      enabled_tools: [{ key: 'request_appointment', version: 1 }],
      tool_configurations: {
        request_appointment: {
          provider: 'calendly',
          url: 'https://calendly.com/cqalerts3/30min',
          fallback_mode: 'approved_link',
          link_label: 'Book a meeting',
          website_presentation: 'calendar_embed'
        }
      }
    ).call
    turn.update!(
      decision_payload: turn.decision_payload.merge('microsite_section_types' => ['booking_section'])
    )

    section = described_class.call(turn).content.fetch('sections').sole

    expect(section).to eq(
      'type' => 'booking_section',
      'title' => 'Book a meeting',
      'provider' => 'calendly',
      'url' => 'https://calendly.com/cqalerts3/30min'
    )
  end

  it 'does not create an ungrounded artifact when selected evidence is absent' do
    turn.evidence.delete_all

    expect(described_class.call(turn)).to be_nil
    expect(ChatRing::MicrositeArtifact.where(ai_turn: turn)).to be_empty
  end

  it 'allows the guarded native commit to link its Message exactly once' do
    artifact = described_class.call(turn)
    message = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: connection.agent_bot,
      message_type: :outgoing,
      content: 'Grounded response'
    )

    expect { artifact.update!(message: message) }.to change(artifact, :message_id).from(nil).to(message.id)

    other = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: connection.agent_bot,
      message_type: :outgoing,
      content: 'Different response'
    )
    expect { artifact.update!(message: other) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(artifact.reload.message).to eq(message)
  end
end
