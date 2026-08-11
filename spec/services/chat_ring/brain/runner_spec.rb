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

  it 'persists heading-less provider evidence as an empty path' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(accepted_evidence_set(heading_path: nil))
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'reply', 'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
      )
    )

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ready_to_commit
    expect(turn.evidence.first.heading_path).to eq([])
  end

  it 'retrieves the raw follow-up and its bounded native context before one model call' do
    history_turn = build_turn(with_history: true)
    history_turn.trigger_message.update!(content: 'How does it work?')
    queries = []
    retrieved_sets = []
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve) do |query:, **|
      queries << query
      result = query.include?('Earlier question about the Website Widget') ? evidence_set : empty_evidence_set
      retrieved_sets << result
      result
    end
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'reply', 'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
      )
    )

    described_class.new(history_turn, provider: provider).call

    contextual_query = <<~QUERY.chomp
      Earlier question about the Website Widget
      How does it work?
    QUERY
    expect(queries).to contain_exactly('How does it work?', contextual_query)
    expect(retrieved_sets.map { |set| [set.knowledge_index_id, set.provider, set.provider_release, set.status] }).to eq(
      [[nil, 'docs_gpt', 'release', 'insufficient_evidence'], [nil, 'docs_gpt', 'release', 'accepted']]
    )
    expect(history_turn.reload).to have_attributes(status: 'ready_to_commit', failure_code: nil)
    expect(provider).to have_received(:call).once
    expect(history_turn.reload.evidence.pluck(:evidence_id)).to eq(['evidence-1'])
  end

  it 'uses bounded native history for a typed Conversation reply when retrieval has insufficient evidence' do
    history_turn = build_turn(with_history: true)
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'context_reply',
        'response_text' => 'You previously asked about the Website Widget.',
        'reason_code' => 'conversation_history',
        'evidence_ids' => []
      )
    )

    described_class.new(history_turn, provider: provider).call

    expect(provider).to have_received(:call).once
    expect(history_turn.reload).to be_status_ready_to_commit
    expect(history_turn.decision_payload).to include(
      'decision_type' => 'context_reply', 'reason_code' => 'conversation_history'
    )
    expect(history_turn.outbound_commit).to be_outcome_type_reply
  end

  it 'uses the configured fallback without inference when neither evidence nor prior history exists' do
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)

    described_class.new(turn, provider: provider).call

    expect(provider).not_to have_received(:call)
    expect(turn.reload).to be_status_cancelled
    expect(turn.decision_payload).to include('decision_type' => 'abstain', 'reason_code' => 'insufficient_evidence')
  end

  it 'prepares a newly activated published Playbook question without retrieval or inference' do
    guided_turn = build_turn(playbook_question: 'What service do you need?')

    expect { described_class.new(guided_turn, provider: provider).call }.not_to change(Message, :count)

    expect(ChatRing::Knowledge::Retriever).not_to have_received(:retrieve)
    expect(provider).not_to have_received(:call)
    expect(guided_turn.reload).to have_attributes(status: 'ready_to_commit', decision_type: 'clarification')
    expect(guided_turn.decision_payload).to include(
      'response_text' => 'What service do you need?',
      'reason_code' => 'playbook_question'
    )
    expect(guided_turn.inbox_playbook_execution.reload).to be_status_active
  end

  it 'classifies a typed Playbook answer without evidence and commits the server-selected branch natively' do
    _, answer_turn = progress_playbook_to_waiting('Internet service')
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'playbook',
        'response_text' => '',
        'reason_code' => 'answered_pending_question',
        'evidence_ids' => [],
        'playbook_control' => { 'action' => 'submit_answer', 'answer_value' => 'Internet service' }
      )
    )

    described_class.new(answer_turn, provider: provider).call
    ChatRing::OutboundCommitJob.perform_now(answer_turn.id)

    expect(provider).to have_received(:call).once
    expect(answer_turn.reload).to be_status_committed
    expect(answer_turn.inbox_playbook_execution.reload).to have_attributes(
      status: 'completed',
      current_step_id: 'complete',
      collected_fields: { 'need' => 'Internet service' }
    )
    expect(answer_turn.outbound_commit.message).to have_attributes(
      content: 'Thank you. Your request is complete.',
      sender: answer_turn.expected_agent_bot
    )
  end

  it 'answers a grounded side question and resumes the exact pending Playbook question' do
    _, side_turn = progress_playbook_to_waiting('Does the Website Widget work?')
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'playbook',
        'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered_side_question',
        'evidence_ids' => ['evidence-1'],
        'playbook_control' => { 'action' => 'answer_side_question' }
      )
    )

    described_class.new(side_turn, provider: provider).call
    ChatRing::OutboundCommitJob.perform_now(side_turn.id)

    expect(side_turn.reload).to be_status_committed
    expect(side_turn.inbox_playbook_execution.reload).to have_attributes(
      status: 'waiting_for_customer',
      current_step_id: 'ask_need',
      collected_fields: {}
    )
    expect(side_turn.outbound_commit.message.content).to eq(
      "Widgets are supported.\n\nWhat service do you need?"
    )
    expect(side_turn.outbound_commit.message.content_attributes.fetch('chatring_citations')).to contain_exactly(
      include('title' => 'Widgets', 'url' => 'https://example.com/widgets')
    )
  end

  it 'allows an authorized semantic appointment request without evidence and prepares no Message directly' do
    appointment_turn = build_turn(appointment_tool: true)
    ChatRing::Tools::PolicyPublisher.new(
      workspace: appointment_turn.workspace,
      inbox: appointment_turn.conversation.inbox,
      actor: create(:user, account: appointment_turn.conversation.account, role: :administrator),
      expected_lock_version: 0,
      enabled_tools: [{ 'key' => 'request_appointment', 'version' => 1 }],
      tool_configurations: {
        'request_appointment' => {
          'provider' => 'calendly', 'url' => 'https://calendly.com/cqalerts3/30min',
          'fallback_mode' => 'approved_link', 'link_label' => 'Book a demo'
        }
      }
    ).call
    allow(ChatRing::Knowledge::Retriever).to receive(:retrieve).and_return(empty_evidence_set)
    allow(provider).to receive(:call).and_return(
      ChatRing::Brain::RubyLlmProvider::Result.new(
        payload: {
          'decision_type' => 'request_appointment', 'response_text' => '',
          'reason_code' => 'visitor_requested_demo', 'evidence_ids' => [],
          'tool_request' => {
            'key' => 'request_appointment', 'version' => 1,
            'arguments' => { 'reason_code' => 'visitor_requested_demo' }
          }
        },
        input_tokens: 20,
        output_tokens: 8,
        response_digest: Digest::SHA256.hexdigest('appointment')
      )
    )

    expect { described_class.new(appointment_turn, provider: provider).call }.not_to change(Message, :count)

    expect(provider).to have_received(:call).once
    expect(appointment_turn.reload).to be_status_ready_to_commit
    expect(appointment_turn.outbound_commit).to be_outcome_type_tool
    expect(appointment_turn.tool_execution).to have_attributes(status: 'pending', tool_key: 'request_appointment')
  end

  it 'does not run when Chatwoot ownership is no longer eligible' do
    turn.conversation.update!(status: :open, assignee_agent_bot: nil)

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ineligible
    expect(turn.decision_type).to eq('conversation_not_pending')
    expect(provider).not_to have_received(:call)
  end

  it 'records a failed attempt and releases the turn for a bounded retry after a provider failure' do
    allow(provider).to receive(:call).and_raise(ChatRing::Brain::RubyLlmProvider::Error.new('provider_unavailable'))

    expect { described_class.new(turn, provider: provider).call }.to raise_error do |error|
      expect(error.class.name).to eq('ChatRing::Brain::Runner::RetryableError')
      expect(error.message).to eq('provider_unavailable')
    end

    expect(turn.reload).to be_status_received
    expect(turn.failure_code).to eq('provider_unavailable')
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

  it 'enforces one durable provider-attempt cap across delayed and recovery job chains' do
    capped_turn = build_turn(handoff_on_provider_failure: true)
    2.times do |position|
      capped_turn.attempts.create!(
        attempt_number: position + 1,
        provider: 'openai',
        model: 'gpt-5.4',
        status: :failed,
        request_digest: Digest::SHA256.hexdigest("prior-attempt-#{position}"),
        started_at: 1.minute.ago,
        completed_at: 1.minute.ago,
        failure_code: 'provider_unavailable'
      )
    end
    allow(provider).to receive(:call).and_raise(ChatRing::Brain::RubyLlmProvider::Error.new('provider_unavailable'))

    expect { described_class.new(capped_turn, provider: provider).call }.to raise_error(ChatRing::Brain::Runner::RetryableError)
    expect { described_class.new(capped_turn.reload, provider: provider).call }.not_to raise_error

    expect(provider).to have_received(:call).once
    expect(capped_turn.reload.attempts.count).to eq(ChatRing::AiTurn::MAX_PROVIDER_ATTEMPTS)
    expect(capped_turn).to be_status_ready_to_commit
    expect(capped_turn.outbound_commit).to have_attributes(status: 'pending', outcome_type: 'handoff')
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

  it 'leaves native Inbox hours to template handling and final human routing instead of disabling AI globally' do
    turn
    inbox = turn.conversation.inbox
    inbox.update!(working_hours_enabled: true)
    inbox.working_hours.today.update!(closed_all_day: true, open_all_day: false)
    allow(provider).to receive(:call).and_return(
      provider_result(
        'decision_type' => 'reply', 'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
      )
    )

    described_class.new(turn, provider: provider).call

    expect(turn.reload).to be_status_ready_to_commit
    expect(turn.decision_type).to eq('reply')
    expect(provider).to have_received(:call).once
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

  it 'supersedes the exact active Playbook when its native Assistant binding changes during inference' do
    _, playbook_turn = progress_playbook_to_waiting('Internet service')
    allow(provider).to receive(:call) do
      playbook_turn.inbox_assistant_binding.update!(status: :inactive)
      provider_result(
        'decision_type' => 'playbook',
        'response_text' => '',
        'reason_code' => 'answered_pending_question',
        'evidence_ids' => [],
        'playbook_control' => { 'action' => 'submit_answer', 'answer_value' => 'Internet service' }
      )
    end

    described_class.new(playbook_turn, provider: provider).call

    expect(playbook_turn.reload).to have_attributes(status: 'ineligible', decision_type: 'binding_inactive')
    expect(playbook_turn.inbox_playbook_execution.reload).to be_status_superseded
    expect(playbook_turn.inbox_playbook_execution.transition_history.last).to include(
      'action' => 'native_runtime_superseded',
      'failure_code' => 'binding_inactive'
    )
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

  def build_turn(handoff_on_provider_failure: false, appointment_tool: false, playbook_question: nil, with_history: false)
    account, workspace, inbox = build_runtime_scope
    connection = configure_runtime(
      workspace: workspace,
      inbox: inbox,
      handoff_on_provider_failure: handoff_on_provider_failure,
      appointment_tool: appointment_tool
    )
    publish_question_playbook(workspace, inbox, playbook_question) if playbook_question
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    if with_history
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, sender: conversation.contact, private: false,
                       content: 'Earlier question about the Website Widget')
    end
    message = create_managed_message(
      account: account,
      inbox: inbox,
      conversation: conversation,
      content: playbook_question ? 'Pricing options' : 'Do you support widgets?'
    )
    complete_native_automation(message)
    ChatRing::AiTurn.find_by!(workspace: workspace, conversation: conversation, trigger_message: message)
  end

  def build_runtime_scope
    account = create(:account)
    [account, account.chat_ring_workspace, create(:channel_widget, account: account).inbox]
  end

  def configure_runtime(workspace:, inbox:, handoff_on_provider_failure:, appointment_tool:)
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    configuration = {}
    configuration[:handoff_policy] = { 'on_provider_failure' => 'handoff' } if handoff_on_provider_failure
    configuration[:tool_grants] = [{ 'key' => 'request_appointment', 'version' => 1 }] if appointment_tool
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope, configuration: configuration).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    connection
  end

  def create_managed_message(account:, inbox:, conversation:, content:)
    ChatRing::ConversationWriteBoundary.new(conversation: conversation).call do
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, sender: conversation.contact, private: false,
                       content: content)
    end
  end

  def publish_question_playbook(workspace, inbox, prompt)
    actor = create(:user, account: inbox.account, role: :administrator)
    playbook = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: 'Pricing discovery',
      purpose: 'Qualify pricing interest.',
      draft_definition: {
        trigger_phrases: ['pricing options'],
        entry_step_id: 'ask_need',
        collected_fields: [{ key: 'need', type: 'string', required: true, native_contact_attribute_key: nil }],
        tool_allowlist: [],
        steps: [
          { id: 'ask_need', kind: 'ask_text', prompt: prompt, field_key: 'need', next_step_id: 'complete' },
          { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you. Your request is complete.' }
        ],
        safety_rules: { on_human_request: 'native_availability', on_side_question: 'answer_then_resume' }
      }
    )
    ChatRing::Playbooks::Publisher.new(playbook: playbook, actor: actor, expected_lock_version: 0).call
  end

  def complete_native_automation(message)
    EventDispatcherJob.perform_now(Message::MESSAGE_CREATED, message.created_at, { message: message, performed_by: nil })
  end

  def progress_playbook_to_waiting(customer_content)
    initial_turn = build_turn(playbook_question: 'What service do you need?')
    described_class.new(initial_turn, provider: provider).call
    ChatRing::OutboundCommitJob.perform_now(initial_turn.id)

    trigger = create_managed_message(
      account: initial_turn.conversation.account,
      inbox: initial_turn.conversation.inbox,
      conversation: initial_turn.conversation,
      content: customer_content
    )
    complete_native_automation(trigger)
    follow_up = ChatRing::AiTurn.find_by!(conversation: initial_turn.conversation, trigger_message: trigger)
    [initial_turn, follow_up]
  end

  def provider_result(payload)
    ChatRing::Brain::RubyLlmProvider::Result.new(
      payload: payload,
      input_tokens: 20,
      output_tokens: 8,
      response_digest: Digest::SHA256.hexdigest(payload.to_json)
    )
  end

  def accepted_evidence_set(heading_path: ['Features'])
    item = ChatRing::Knowledge::Evidence.new(
      id: 'evidence-1', knowledge_index_id: nil, provider: 'docs_gpt', provider_release: 'release',
      provider_source_id: 'source', provider_chunk_id: 'chunk', source_kind: 'website',
      source_reference: 'https://example.com/widgets', source_title: 'Widgets', public_url: 'https://example.com/widgets',
      heading_path: heading_path, page_locator: nil, page_headings: [], cta_candidates: [], locator: 'https://example.com/widgets',
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
