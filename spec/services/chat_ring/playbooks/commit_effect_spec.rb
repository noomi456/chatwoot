require 'rails_helper'

RSpec.describe ChatRing::Playbooks::CommitEffect do
  let(:prepared) { build_prepared_turn }
  let(:turn) { prepared.fetch(:turn) }
  let(:execution) { turn.inbox_playbook_execution }
  let(:conversation) { turn.conversation }
  let(:service) do
    Conversations::AgentBotConditionalCommitService.new(
      conversation: conversation,
      agent_bot: turn.expected_agent_bot,
      expected_agent_bot_id: turn.expected_agent_bot_id,
      responding_to_message_id: turn.trigger_message_id,
      idempotency_key: turn.outbound_commit.idempotency_key,
      message: { content: 'Caller-supplied content must not control the Playbook question.', content_type: 'text' }
    )
  end

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  it 'moves the execution only when the ordinary AgentBot Message commits' do
    result = service.perform

    expect(result.message).to have_attributes(
      sender: turn.expected_agent_bot,
      content: 'What service do you need?',
      private: false
    )
    expect(execution.reload).to have_attributes(
      status: 'waiting_for_customer',
      last_outcome_message: result.message
    )
    expect(execution.transition_history).to contain_exactly(
      include(
        'action' => 'ask_current_step',
        'from_step_id' => 'ask_need',
        'to_step_id' => 'ask_need',
        'trigger_message_id' => turn.trigger_message_id,
        'outcome_message_id' => result.message.id
      )
    )
  end

  it 'does not advance or ask twice when the same native outcome is retried' do
    original = service.perform.message

    expect { service.perform }.not_to change(Message, :count)

    expect(execution.reload.transition_history.one?).to be(true)
    expect(turn.outbound_commit.reload.chatwoot_message_id).to eq(original.id)
  end

  it 'rolls back the native Message and ledger when the execution transition fails' do
    effect = described_class.new(turn: turn.reload, execution: execution.reload)
    allow(described_class).to receive(:new).and_return(effect)
    allow(effect).to receive(:apply!).and_raise(ActiveRecord::RecordInvalid.new(execution))

    expect { service.perform }.to raise_error(ActiveRecord::RecordInvalid)
    expect(conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
    expect(turn.outbound_commit.reload).to be_status_pending
    expect(execution.reload).to be_status_active
  end

  it 'rejects a stale pinned execution without creating a Message or changing execution state' do
    execution.update!(collected_fields: { 'need' => 'changed elsewhere' })

    expect { service.perform }
      .to raise_error(Conversations::AgentBotConditionalCommitService::PreconditionFailed, 'playbook_execution_changed')

    expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'playbook_execution_changed')
    expect(execution.reload).to be_status_active
    expect(conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
  end

  it 'preserves native supersession provenance when a newer customer message also advances the execution' do
    execution.update!(collected_fields: { 'need' => 'changed elsewhere' })
    create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation,
                     sender: conversation.contact, message_type: :incoming, private: false, content: 'One more detail')

    expect { service.perform }
      .to raise_error(Conversations::AgentBotConditionalCommitService::PreconditionFailed, 'newer_customer_message')
    expect(turn.outbound_commit.reload.failure_code).to eq('newer_customer_message')
  end

  it 'coerces a submitted answer and advances the pinned execution in the same native Message commit' do
    service.perform
    answer_turn = build_follow_up_turn(
      'decision_type' => 'playbook',
      'response_text' => '',
      'reason_code' => 'answered_pending_question',
      'evidence_ids' => [],
      'playbook_control' => { 'action' => 'submit_answer', 'answer_value' => 'Internet service' }
    )

    result = service_for(answer_turn).perform

    expect(result.message.content).to eq('Thank you. Your request is complete.')
    expect(execution.reload).to have_attributes(status: 'completed', current_step_id: 'complete')
    expect(execution.collected_fields).to eq('need' => 'Internet service')
    expect(execution.field_sources.fetch('need')).to include(
      'message_id' => answer_turn.trigger_message_id,
      'ai_turn_id' => answer_turn.id,
      'playbook_version_id' => execution.inbox_playbook_version_id,
      'step_id' => 'ask_need'
    )
    expect(execution.transition_history.last).to include(
      'action' => 'submit_answer',
      'from_step_id' => 'ask_need',
      'to_step_id' => 'complete',
      'outcome_message_id' => result.message.id
    )
  end

  it 'answers a grounded side question and resumes the exact published pending question without advancing' do
    service.perform
    side_turn = build_follow_up_turn(
      'decision_type' => 'playbook',
      'response_text' => 'Installation is included.',
      'reason_code' => 'answered_side_question',
      'evidence_ids' => ['evidence-1'],
      'playbook_control' => { 'action' => 'answer_side_question' }
    )

    result = service_for(side_turn).perform

    expect(result.message.content).to eq("Installation is included.\n\nWhat service do you need?")
    expect(execution.reload).to have_attributes(status: 'waiting_for_customer', current_step_id: 'ask_need')
    expect(execution.collected_fields).to eq({})
    expect(execution.transition_history.last).to include(
      'action' => 'answer_side_question',
      'from_step_id' => 'ask_need',
      'to_step_id' => 'ask_need'
    )
  end

  it 'does not repeat the pending question when the model echoes it at the end of a side answer' do
    service.perform
    side_turn = build_follow_up_turn(
      'decision_type' => 'playbook',
      'response_text' => "Installation is included.\n\nWhat service do you need?",
      'reason_code' => 'answered_side_question',
      'evidence_ids' => ['evidence-1'],
      'playbook_control' => { 'action' => 'answer_side_question' }
    )

    result = service_for(side_turn).perform

    expect(result.message.content).to eq("Installation is included.\n\nWhat service do you need?")
    expect(result.message.content.scan('What service do you need?').count).to eq(1)
    expect(execution.reload).to have_attributes(status: 'waiting_for_customer', current_step_id: 'ask_need')
  end

  it 'does not repeat the pending question when the model changes only its interrogative' do
    service.perform
    side_turn = build_follow_up_turn(
      'decision_type' => 'playbook',
      'response_text' => "Installation is included.\n\nWhich service do you need?",
      'reason_code' => 'answered_side_question',
      'evidence_ids' => ['evidence-1'],
      'playbook_control' => { 'action' => 'answer_side_question' }
    )

    result = service_for(side_turn).perform

    expect(result.message.content).to eq("Installation is included.\n\nWhat service do you need?")
    expect(result.message.content.scan(/(?:What|Which) service do you need\?/).count).to eq(1)
    expect(execution.reload).to have_attributes(status: 'waiting_for_customer', current_step_id: 'ask_need')
  end

  it 'declines an unsupported side question with approved copy and resumes the exact pending question' do
    service.perform
    resume_turn = build_follow_up_turn(
      'decision_type' => 'playbook',
      'response_text' => '',
      'reason_code' => 'side_question_unsupported',
      'evidence_ids' => [],
      'playbook_control' => { 'action' => 'resume_pending_question' }
    )

    result = service_for(resume_turn).perform

    expect(result.message.content).to eq(
      "I don't have enough verified information to answer that.\n\nWhat service do you need?"
    )
    expect(execution.reload).to have_attributes(status: 'waiting_for_customer', current_step_id: 'ask_need')
    expect(execution.transition_history.last).to include('action' => 'resume_pending_question')
  end

  it 'terminalizes the pinned execution when a native public human reply supersedes the AI outcome' do
    agent = create(:user, account: conversation.account, role: :agent)
    create(:inbox_member, inbox: conversation.inbox, user: agent)
    create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation,
                     sender: agent, message_type: :outgoing, private: false, content: 'I will take this')

    ChatRing::OutboundCommitJob.perform_now(turn.id)

    expect(turn.reload).to have_attributes(status: 'superseded', failure_code: 'newer_human_reply')
    expect(execution.reload).to be_status_handed_off
    expect(execution.transition_history.last).to include(
      'action' => 'native_human_takeover',
      'failure_code' => 'newer_human_reply'
    )
    expect(conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
  end

  it 'supersedes the pinned execution when the native Inbox binding changes before commit' do
    turn.inbox_assistant_binding.update!(status: :inactive)

    ChatRing::OutboundCommitJob.perform_now(turn.id)

    expect(turn.reload).to have_attributes(status: 'cancelled', failure_code: 'binding_inactive')
    expect(execution.reload).to be_status_superseded
    expect(execution.transition_history.last).to include(
      'action' => 'native_runtime_superseded',
      'failure_code' => 'binding_inactive'
    )
    expect(conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
  end

  it 'terminalizes the exact pinned execution in the same successful native AI handoff transaction' do
    context = ChatRingPlaybookSpecSupport.build
    handoff_turn = context.fetch(:turn)
    handoff_turn.update!(
      status: :ready_to_commit,
      decision_type: 'handoff',
      decision_payload: {
        'decision_type' => 'handoff',
        'response_text' => '',
        'reason_code' => 'human_requested',
        'evidence_ids' => []
      }
    )
    ChatRing::OutboundCommitPreparer.call(handoff_turn, 'handoff')
    agent = create(:user, account: handoff_turn.conversation.account, role: :agent)
    create(:inbox_member, inbox: handoff_turn.conversation.inbox, user: agent)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')

    ChatRing::OutboundCommitJob.perform_now(handoff_turn.id)

    expect(handoff_turn.reload).to be_status_handed_off
    expect(handoff_turn.conversation.reload).to be_open
    expect(handoff_turn.conversation.assignee_agent_bot).to be_nil
    expect(handoff_turn.inbox_playbook_execution.reload).to be_status_handed_off
    expect(handoff_turn.inbox_playbook_execution.transition_history.last).to include(
      'action' => 'native_human_takeover',
      'failure_code' => 'human_assigned'
    )
  end

  it 'stops the pinned Playbook and preserves a callback request when no eligible human is online' do
    context = ChatRingPlaybookSpecSupport.build
    handoff_turn = context.fetch(:turn)
    handoff_turn.update!(
      status: :ready_to_commit,
      decision_type: 'handoff',
      decision_payload: {
        'decision_type' => 'handoff',
        'response_text' => '',
        'reason_code' => 'human_requested',
        'evidence_ids' => []
      }
    )
    ChatRing::OutboundCommitPreparer.call(handoff_turn, 'handoff')
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})

    ChatRing::OutboundCommitJob.perform_now(handoff_turn.id)

    expect(handoff_turn.reload).to be_status_committed
    expect(handoff_turn.conversation.reload).to be_pending
    expect(handoff_turn.inbox_playbook_execution.reload).to be_status_stopped
    expect(handoff_turn.inbox_playbook_execution.transition_history.last).to include(
      'action' => 'human_unavailable_callback_requested',
      'failure_code' => 'no_eligible_agent_online'
    )
    expect(handoff_turn.outbound_commit.message.content).to start_with('Our team is currently unavailable.')
  end

  private

  def build_prepared_turn
    base = ChatRingPlaybookSpecSupport.build
    ChatRing::Playbooks::InitialQuestionPreparer.call(
      base.fetch(:turn),
      context_digest: Digest::SHA256.hexdigest('playbook-context')
    )
    base
  end

  def build_follow_up_turn(decision_payload)
    trigger = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation,
                               sender: conversation.contact, message_type: :incoming, private: false,
                               content: 'Follow-up Playbook input')
    execution.reload.update!(last_trigger_message: trigger)
    follow_up = ChatRing::AiTurn.create!(follow_up_attributes(trigger, decision_payload))
    ChatRing::OutboundCommitPreparer.call(follow_up, 'playbook')
    follow_up
  end

  def follow_up_attributes(trigger, decision_payload)
    {
      workspace: turn.workspace,
      conversation: conversation,
      trigger_message: trigger,
      inbox_assistant_binding: turn.inbox_assistant_binding,
      binding_version: turn.binding_version,
      assistant: turn.assistant,
      assistant_version: turn.assistant_version,
      expected_agent_bot: turn.expected_agent_bot,
      inbox_playbook_execution: execution,
      playbook_execution_lock_version: execution.lock_version,
      playbook_step_id: execution.current_step_id,
      status: :ready_to_commit,
      decision_type: 'playbook',
      decision_payload: decision_payload,
      native_handling_snapshot: { 'automation' => { 'completed' => true, 'effects' => [] } },
      deadline_at: 2.minutes.from_now
    }
  end

  def service_for(candidate_turn)
    Conversations::AgentBotConditionalCommitService.new(
      conversation: conversation,
      agent_bot: candidate_turn.expected_agent_bot,
      expected_agent_bot_id: candidate_turn.expected_agent_bot_id,
      responding_to_message_id: candidate_turn.trigger_message_id,
      idempotency_key: candidate_turn.outbound_commit.idempotency_key,
      message: { content: 'Caller-controlled content', content_type: 'text' }
    )
  end
end
