require 'rails_helper'
require 'timeout'

RSpec.describe ChatRing::OutboundCommitJob, type: :job do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:version) { ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call }
  let(:connection) do
    version
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
                     message_type: :incoming, private: false, content: 'Do you support widgets?')
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
      native_handling_snapshot: { 'automation' => { 'completed' => true, 'effects' => [] } },
      deadline_at: 2.minutes.from_now,
      decision_type: 'reply',
      decision_payload: {
        'decision_type' => 'reply',
        'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered',
        'evidence_ids' => ['evidence-1']
      }
    )
  end

  context 'with the public response gate open' do
    before do
      stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    end

    it 'commits exactly one ordinary message across job retries' do
      2.times { described_class.perform_now(turn.id) }

      expect(turn.reload).to be_status_committed
      expect(turn.outbound_commit).to be_status_committed
      expect(conversation.messages.outgoing.where(sender: connection.agent_bot).pluck(:content)).to eq(['Widgets are supported.'])
    end

    it 'commits one server-rendered Playbook question and then finalizes the historical turn pin' do
      context = ChatRing::Playbooks::InitialQuestionPreparerSpecSupport.build
      playbook_turn = context.fetch(:turn)
      playbook_turn.update!(status: :received)
      allow(ChatRing::Knowledge::Retriever).to receive(:active_index_id).and_return(nil)

      expect(ChatRing::Knowledge::Retriever).not_to receive(:retrieve)
      perform_enqueued_jobs(only: described_class) do
        ChatRing::AiTurnJob.perform_now(playbook_turn.id)
      end

      expect(playbook_turn.reload).to be_status_committed
      expect(playbook_turn.inbox_playbook_execution.reload).to have_attributes(
        status: 'waiting_for_customer',
        last_outcome_message_id: playbook_turn.outbound_commit.chatwoot_message_id
      )
      expect(playbook_turn.outbound_commit.message.content).to eq('What service do you need?')
    end

    it 'creates one reply ledger and Message when duplicate jobs race before ledger creation' do
      turn
      run_duplicate_jobs_at_ledger_creation

      expect(turn.reload).to be_status_committed
      expect(ChatRing::OutboundCommit.where(ai_turn: turn, outcome_type: :reply).count).to eq(1)
      expect(conversation.messages.outgoing.where(sender: connection.agent_bot).pluck(:content)).to eq(['Widgets are supported.'])
    end

    it 'reconciles to the same Message after a crash between reply commit and turn finalization' do
      turn
      fail_finalization = true
      allow(ChatRing::AiTurn).to receive(:find_by).with(id: turn.id).and_return(turn)
      allow(turn).to receive(:update!).and_wrap_original do |original, attributes|
        if fail_finalization && attributes[:status] == :committed
          fail_finalization = false
          raise Timeout::Error, 'simulated worker loss after commit'
        end

        original.call(attributes)
      end

      expect { described_class.perform_now(turn.id) }.to raise_error(Timeout::Error)
      committed_message_id = turn.outbound_commit.reload.chatwoot_message_id
      expect(turn.reload).to be_status_ready_to_commit

      expect { described_class.perform_now(turn.id) }.not_to(change(Message, :count))

      expect(turn.reload).to be_status_committed
      expect(turn.outbound_commit.reload.chatwoot_message_id).to eq(committed_message_id)
    end

    it 'performs an expected-owner handoff without creating a public message' do
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      expect { described_class.perform_now(turn.id) }.not_to change(Message, :count)
      expect(turn.reload).to be_status_handed_off
      expect(turn.outbound_commit).to be_status_committed
      expect(turn.outbound_commit).to be_outcome_type_handoff
      expect(turn.outbound_commit.message).to be_nil
      expect(conversation.reload).to be_open
      expect(conversation.assignee_agent_bot).to be_nil
    end

    it 'creates one handoff ledger when duplicate jobs race before ledger creation' do
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      run_duplicate_jobs_at_ledger_creation

      expect(turn.reload).to be_status_handed_off
      expect(ChatRing::OutboundCommit.where(ai_turn: turn, outcome_type: :handoff).count).to eq(1)
      expect(conversation.reload).to be_open
      expect(conversation.assignee_agent_bot).to be_nil
    end

    it 'records the handoff before dispatching the native event and remains idempotent on service retry' do
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      turn
      observed_commit_statuses = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, *arguments|
        observed_commit_statuses << ChatRing::OutboundCommit.find_by(ai_turn: turn)&.status if event == Conversation::CONVERSATION_BOT_HANDOFF
        original.call(event, *arguments)
      end

      described_class.perform_now(turn.id)
      result = Conversations::AgentBotConditionalHandoffService.new(
        turn: turn.reload,
        outbound_commit: turn.outbound_commit
      ).perform

      expect(result.idempotent).to be(true)
      expect(observed_commit_statuses).to eq(%w[committed])
      expect(ChatRing::OutboundCommit.where(ai_turn: turn).count).to eq(1)
    end

    it 'persists a rejected handoff before reporting the failed precondition' do
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      turn
      conversation.bot_handoff!

      expect { described_class.perform_now(turn.id) }.not_to(change { conversation.messages.outgoing.count })

      expect(turn.reload).to be_status_cancelled
      expect(turn.failure_code).to eq('conversation_not_pending')
      expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'conversation_not_pending')

      conversation.update!(status: :pending, assignee_agent_bot: connection.agent_bot)
      service = Conversations::AgentBotConditionalHandoffService.new(
        turn: turn,
        outbound_commit: turn.outbound_commit
      )
      expect { service.perform }
        .to raise_error(Conversations::AgentBotConditionalCommitService::PreconditionFailed, 'conversation_not_pending')
      expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'conversation_not_pending')
    end

    it 'does not commit after human takeover wins first' do
      turn
      conversation.bot_handoff!

      expect { described_class.perform_now(turn.id) }.not_to(change { conversation.messages.outgoing.count })
      expect(turn.reload).to be_status_cancelled
      expect(turn.failure_code).to eq('conversation_not_pending')
    end

    it 'records a newer public human reply as superseding the ready turn' do
      turn
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent,
                       message_type: :outgoing, private: false, content: 'I will take this')

      described_class.perform_now(turn.id)

      expect(turn.reload).to be_status_superseded
      expect(turn.failure_code).to eq('newer_human_reply')
      expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'newer_human_reply')
      expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
    end

    it 'rejects a reply after the turn deadline expires' do
      travel_to(turn.deadline_at + 1.second)

      expect { described_class.perform_now(turn.id) }.not_to(change { conversation.messages.outgoing.count })

      expect(turn.reload).to be_status_cancelled
      expect(turn.failure_code).to eq('turn_deadline_expired')
      expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'turn_deadline_expired')
    end
  end

  context 'with the public response gate closed' do
    it 'does not commit a customer-visible message' do
      expect { described_class.perform_now(turn.id) }.not_to(change { conversation.messages.outgoing.count })

      expect(turn.reload).to be_status_ready_to_commit
      expect(turn.outbound_commit).to be_nil
    end
  end

  def run_duplicate_jobs_at_ledger_creation
    barrier = Concurrent::CyclicBarrier.new(2)
    allow(ChatRing::OutboundCommit).to receive(:create!).and_wrap_original do |original, *arguments, &block|
      barrier.wait
      original.call(*arguments, &block)
    end
    errors = Concurrent::Array.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { described_class.perform_now(turn.id) }
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
  end
end
