require 'rails_helper'

RSpec.describe ChatRing::Brain::Runner do
  let(:turn) { build_turn }
  let(:provider) { instance_double(ChatRing::Brain::RubyLlmProvider) }
  let(:evidence_set) { accepted_evidence_set }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    allow(ChatRing::Knowledge::Retriever).to receive(:active_index_id).and_return(nil)
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(evidence_set)
    allow(provider).to receive(:call)
  end

  it 'persists a grounded decision, exact evidence, and one successful provider attempt without creating a Message' do
    result = ChatRing::Brain::RubyLlmProvider::Result.new(
      payload: {
        'decision_type' => 'reply', 'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
      },
      input_tokens: 40,
      output_tokens: 12,
      response_digest: Digest::SHA256.hexdigest('response')
    )
    allow(provider).to receive(:call).and_return(result)
    turn

    expect do
      described_class.new(turn, provider: provider).call
    end.not_to change(Message, :count)

    expect(turn.reload).to be_status_ready_to_commit
    expect(turn.decision_payload).to include('decision_type' => 'reply', 'evidence_ids' => ['evidence-1'])
    expect(turn.outbound_commit).to have_attributes(status: 'pending', outcome_type: 'reply')
    expect(turn.context_metadata).to include('projection_version' => 1, 'contact_fields_included' => [])
    expect(turn.evidence.first).to have_attributes(evidence_id: 'evidence-1', excerpt: 'Widgets are supported.')
    expect(turn.attempts.first).to be_status_succeeded
  end

  it 'abstains deterministically without calling the model when retrieval has insufficient evidence' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)

    described_class.new(turn, provider: provider).call

    expect(provider).not_to have_received(:call)
    expect(turn.reload).to be_status_cancelled
    expect(turn.decision_payload).to include('decision_type' => 'abstain', 'reason_code' => 'insufficient_evidence')
  end

  it 'does not run when Chatwoot ownership is no longer eligible' do
    turn.conversation.update!(status: :open, assignee_agent_bot: nil)

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('conversation_not_pending')
    expect(provider).not_to have_received(:call)
  end

  it 'records a failed attempt and releases the turn for a bounded retry after a provider failure' do
    allow(provider).to receive(:call).and_raise(ChatRing::Brain::RubyLlmProvider::Error.new('provider_failed'))

    expect { described_class.new(turn, provider: provider).call }.to raise_error do |error|
      expect(error.class.name).to eq('ChatRing::Brain::Runner::RetryableError')
      expect(error.message).to eq('provider_failed')
    end

    expect(turn.reload).to be_status_received
    expect(turn.failure_code).to eq('provider_failed')
    expect(turn.attempts.first).to be_status_failed
  end

  it 'does not retrieve or infer after the turn deadline expires' do
    travel_to(turn.deadline_at + 1.second)

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_failed
    expect(turn.failure_code).to eq('turn_deadline_expired')
    expect(ChatRing::Knowledge::Retriever).not_to have_received(:retrieve)
    expect(provider).not_to have_received(:call)
  end

  it 'discards a provider result that arrives after the turn deadline' do
    allow(provider).to receive(:call) do
      travel_to(turn.deadline_at + 1.second)
      ChatRing::Brain::RubyLlmProvider::Result.new(
        payload: {
          'decision_type' => 'reply', 'response_text' => 'Late reply',
          'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
        },
        input_tokens: 10,
        output_tokens: 5,
        response_digest: Digest::SHA256.hexdigest('expired')
      )
    end

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_failed
    expect(turn.decision_type).to eq('abstain')
    expect(turn.attempts.first).to have_attributes(status: 'failed', failure_code: 'turn_deadline_expired')
  end

  it 'does not retry a permanent provider configuration failure' do
    allow(provider).to receive(:call).and_raise(ChatRing::Brain::RubyLlmProvider::Error.new('provider_configuration_error'))

    expect { described_class.new(turn, provider: provider).call }.not_to raise_error

    expect(turn.reload).to have_attributes(status: 'failed', failure_code: 'provider_configuration_error')
    expect(turn.attempts.count).to eq(1)
  end

  it 'terminalizes a retrieval configuration failure instead of stranding a running turn' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve)
      .and_raise(ChatRing::Knowledge::Retriever::Error, 'Pinned index is invalid')

    expect { described_class.new(turn, provider: provider).call }.not_to raise_error

    expect(turn.reload).to have_attributes(status: 'failed')
    expect(turn.failure_code).to start_with('knowledge_configuration_error:')
    expect(provider).not_to have_received(:call)
  end

  it 'passes a retrieval timeout bounded by the remaining turn budget' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)
    travel_to(turn.deadline_at - 5.seconds)

    described_class.new(turn, provider: provider).call

    expect(ChatRing::Knowledge::Retriever).to have_received(:retrieve).with(hash_including(timeout_seconds: 3))
  end

  it 'respects native Inbox working hours' do
    turn
    inbox = turn.conversation.inbox
    inbox.update!(working_hours_enabled: true)
    inbox.working_hours.today.update!(closed_all_day: true, open_all_day: false)

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('outside_inbox_hours')
    expect(provider).not_to have_received(:call)
  end

  it 'suppresses a completed decision when a human takes ownership during inference' do
    allow(provider).to receive(:call) do
      turn.conversation.update!(status: :open, assignee_agent_bot: nil)
      ChatRing::Brain::RubyLlmProvider::Result.new(
        payload: {
          'decision_type' => 'reply', 'response_text' => 'Late reply',
          'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
        },
        input_tokens: 10,
        output_tokens: 5,
        response_digest: Digest::SHA256.hexdigest('late')
      )
    end

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_payload).to eq({})
  end

  it 'suppresses a completed decision when the Inbox Assistant binding changes during inference' do
    allow(provider).to receive(:call) do
      turn.inbox_assistant_binding.update!(status: :inactive)
      ChatRing::Brain::RubyLlmProvider::Result.new(
        payload: {
          'decision_type' => 'reply', 'response_text' => 'Late reply',
          'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
        },
        input_tokens: 10,
        output_tokens: 5,
        response_digest: Digest::SHA256.hexdigest('stale-binding')
      )
    end

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('binding_inactive')
    expect(turn.decision_payload).to eq({})
  end

  it 'does not call the model when native ownership changes during retrieval' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve) do
      turn.conversation.update!(status: :open, assignee_agent_bot: nil)
      evidence_set
    end

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('conversation_not_pending')
    expect(provider).not_to have_received(:call)
  end

  def build_turn
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    message = create_managed_message(account: account, inbox: inbox, conversation: conversation)
    complete_native_automation(message)
    ChatRing::AiTurn.find_by!(workspace: workspace, conversation: conversation, trigger_message: message)
  end

  def create_managed_message(account:, inbox:, conversation:)
    ChatRing::ConversationWriteBoundary.new(conversation: conversation).call do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, sender: conversation.contact, private: false,
                       content: 'Do you support widgets?')
    end
  end

  def complete_native_automation(message)
    EventDispatcherJob.perform_now(Message::MESSAGE_CREATED, message.created_at, { message: message, performed_by: nil })
  end

  def accepted_evidence_set
    item = ChatRing::Knowledge::Evidence.new(
      id: 'evidence-1', knowledge_index_id: nil, provider: 'docs_gpt', provider_release: 'release',
      provider_source_id: 'source', provider_chunk_id: 'chunk', source_kind: 'website',
      source_reference: 'https://example.com/widgets', source_title: 'Widgets', public_url: 'https://example.com/widgets',
      heading_path: ['Features'], page_locator: nil, page_headings: [], cta_candidates: [], locator: 'https://example.com/widgets',
      authority_class: 'product_documentation', risk_flags: [], excerpt: 'Widgets are supported.',
      source_content_hash: Digest::SHA256.hexdigest('content'), rank: 1, score: 0.8,
      score_kind: 'cosine_similarity', retrieval_strategy: 'classic_cosine'
    )
    evidence_set_with(status: 'accepted', items: [item])
  end

  def empty_evidence_set
    evidence_set_with(status: 'insufficient_evidence', items: [])
  end

  def evidence_set_with(status:, items:)
    ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: nil, provider: 'docs_gpt', provider_release: 'release', query: 'widgets', status: status,
      error_code: nil, latency_ms: 1, retrieval_strategy: 'classic_cosine', retrieval_configuration: {}, items: items.freeze
    )
  end
end
