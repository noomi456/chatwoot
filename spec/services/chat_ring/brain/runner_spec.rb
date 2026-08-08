require 'rails_helper'

RSpec.describe ChatRing::Brain::Runner do
  let(:turn) { build_turn }
  let(:provider) { instance_double(ChatRing::Brain::RubyLlmProvider) }
  let(:evidence_set) { accepted_evidence_set }

  before do
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
    expect(turn.evidence.first).to have_attributes(evidence_id: 'evidence-1', excerpt: 'Widgets are supported.')
    expect(turn.attempts.first).to be_status_succeeded
  end

  it 'abstains deterministically without calling the model when retrieval has insufficient evidence' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)

    described_class.new(turn, provider: provider).call

    expect(provider).not_to have_received(:call)
    expect(turn.reload).to be_status_ready_to_commit
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

    expect do
      described_class.new(turn, provider: provider).call
    end.to raise_error(ChatRing::Brain::Runner::RetryableError, 'provider_failed')

    expect(turn.reload).to be_status_received
    expect(turn.failure_code).to eq('provider_failed')
    expect(turn.attempts.first).to be_status_failed
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

  def build_turn
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:inbox, account: account)
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    version = ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :incoming, sender: conversation.contact, private: false,
                               content: 'Do you support widgets?')
    ChatRing::AiTurn.create!(workspace: workspace, conversation: conversation, trigger_message: message,
                             inbox_assistant_binding: binding, binding_version: binding.binding_version,
                             assistant: assistant, assistant_version: version,
                             expected_agent_bot: connection.agent_bot, status: :received)
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
