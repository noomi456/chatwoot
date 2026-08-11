require 'rails_helper'
require 'timeout'

RSpec.describe ChatRing::OutboundCommitJob, type: :job do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { tool_grants: [{ key: 'request_appointment', version: 1 }] }
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
      context = ChatRingPlaybookSpecSupport.build
      playbook_turn = context.fetch(:turn)
      playbook_turn.update!(status: :received)
      allow(ChatRing::Knowledge::Retriever).to receive(:active_index_id).and_return(nil)

      expect(ChatRing::Knowledge::Retriever).not_to receive(:retrieve)
      perform_enqueued_jobs(only: ->(job) { job.class.name == described_class.name }) do
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

    it 'performs an expected-owner handoff without creating a public message', :aggregate_failures do
      agent = make_human_available
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      expect { described_class.perform_now(turn.id) }.not_to change(Message, :count)
      expect(turn.reload).to be_status_handed_off
      expect(turn.outbound_commit).to be_status_committed
      expect(turn.outbound_commit).to be_outcome_type_human_route
      expect(turn.outbound_commit.message).to be_nil
      expect(conversation.reload).to be_open
      expect(conversation.assignee_agent_bot).to be_nil
      expect(conversation.assignee).to eq(agent)
    end

    it 'creates one handoff ledger when duplicate jobs race before ledger creation' do
      make_human_available
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      run_duplicate_jobs_at_ledger_creation

      expect(turn.reload).to be_status_handed_off
      expect(ChatRing::OutboundCommit.where(ai_turn: turn, outcome_type: :human_route).count).to eq(1)
      expect(conversation.reload).to be_open
      expect(conversation.assignee_agent_bot).to be_nil
    end

    it 'uses native assignment callbacks once and remains idempotent on service retry' do
      agent = make_human_available
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      turn
      observed_commit_statuses = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, *arguments|
        observed_commit_statuses << ChatRing::OutboundCommit.find_by(ai_turn: turn)&.status if event == Events::Types::ASSIGNEE_CHANGED
        original.call(event, *arguments)
      end

      described_class.perform_now(turn.id)
      result = Conversations::AgentBotConditionalHumanRouteService.new(
        turn: turn.reload,
        outbound_commit: turn.outbound_commit
      ).perform

      expect(result.idempotent).to be(true)
      expect(observed_commit_statuses).to eq(%w[committed])
      expect(ChatRing::OutboundCommit.where(ai_turn: turn).count).to eq(1)
      expect(conversation.reload.assignee).to eq(agent)
    end

    it 'recovers native v2 accounting after assignment commits without reassigning', :aggregate_failures do
      agent = make_human_available
      account.enable_features('assignment_v2')
      account.save!
      assignment_policy = create(:assignment_policy, account: account, enabled: true)
      create(:inbox_assignment_policy, inbox: inbox, assignment_policy: assignment_policy)
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })
      limiter = AutoAssignment::RateLimiter.new(inbox: inbox, agent: agent)
      assignment_service = AutoAssignment::AssignmentService.new(inbox: inbox)
      assignment_events = 0
      fail_accounting = true
      allow(AutoAssignment::AssignmentService).to receive(:new).with(inbox: inbox).and_return(assignment_service)
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, event, *arguments|
        assignment_events += 1 if event == Events::Types::ASSIGNEE_CHANGED
        original.call(event, *arguments)
      end
      allow(assignment_service).to receive(:account_assignment).and_wrap_original do |original, *args, **kwargs|
        if fail_accounting
          fail_accounting = false
          raise Timeout::Error, 'simulated Redis loss after native assignment commit'
        end

        original.call(*args, **kwargs)
      end

      expect { described_class.perform_now(turn.id) }.to raise_error(Timeout::Error)
      expect(turn.outbound_commit.reload).to be_status_committed
      expect(turn.reload).to be_status_ready_to_commit
      expect(turn.decision_payload.fetch('assigned_agent_id')).to eq(agent.id)
      expect(conversation.reload.assignee).to eq(agent)
      expect(limiter.current_count).to eq(0)

      expect { described_class.perform_now(turn.id) }.to change(limiter, :current_count).from(0).to(1)
      expect(turn.reload).to be_status_handed_off
      expect(conversation.reload.assignee).to eq(agent)
      expect(assignment_events).to eq(1)

      turn.update!(status: :ready_to_commit)
      expect { described_class.perform_now(turn.id) }.not_to change(limiter, :current_count)
      expect(assignment_events).to eq(1)
    end

    it 'truthfully requests a callback without handing off when no eligible agent is online' do
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      described_class.perform_now(turn.id)

      expect(turn.reload).to be_status_committed
      expect(turn.decision_payload.fetch('routing_outcome')).to eq('human_unavailable_callback_requested')
      expect(turn.outbound_commit).to have_attributes(status: 'committed', outcome_type: 'human_route')
      expect(turn.outbound_commit.message.content).to eq(
        'Our team is currently unavailable. Please leave your preferred callback time here, and a human can follow up in this conversation.'
      )
      expect(conversation.reload).to have_attributes(status: 'pending', assignee_agent_bot: connection.agent_bot)
    end

    it 'uses the Inbox-approved Calendly Tool outside native business hours without a model-supplied URL' do
      publish_appointment_policy
      inbox.update!(working_hours_enabled: true)
      inbox.working_hours.today.update!(closed_all_day: true, open_all_day: false)
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      described_class.perform_now(turn.id)

      execution = turn.reload.tool_execution
      expect(turn).to be_status_committed
      expect(turn.outbound_commit).to have_attributes(status: 'committed', outcome_type: 'human_route')
      expect(execution).to have_attributes(
        status: 'committed',
        tool_key: 'request_appointment',
        authorization_result: 'authorized_human_outside_hours'
      )
      expect(execution.validated_arguments).to eq('reason_code' => 'human_unavailable')
      expect(turn.outbound_commit.message.content).to eq(
        "Our team is currently outside business hours. You can choose an appointment time here:\n\n" \
        "Book a 30 minute meeting\nhttps://calendly.com/cqalerts3/30min"
      )
      expect(turn.outbound_commit.message.content_attributes.fetch('chatring_tool')).to eq(
        'presentation_mode' => 'calendar_embed',
        'provider' => 'calendly',
        'approved_url' => 'https://calendly.com/cqalerts3/30min',
        'link_label' => 'Book a 30 minute meeting'
      )
      expect(conversation.reload).to have_attributes(status: 'pending', assignee_agent_bot: connection.agent_bot)
    end

    it 'does not treat an online agent outside the current Conversation team as eligible' do
      agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: agent)
      other_team = create(:team, account: account)
      conversation.update!(team: other_team)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      described_class.perform_now(turn.id)

      expect(turn.reload).to be_status_committed
      expect(turn.outbound_commit.message.content).to start_with('Our team is currently unavailable.')
      expect(conversation.reload).to be_pending
    end

    it 'does not claim a transfer when native auto assignment is disabled' do
      make_human_available
      inbox.update!(enable_auto_assignment: false)
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      described_class.perform_now(turn.id)

      expect(turn.reload).to be_status_committed
      expect(turn.outbound_commit.message.content).to start_with('We could not connect you to an available human right now.')
      expect(conversation.reload).to be_pending
      expect(conversation.assignee).to be_nil
      expect(conversation.assignee_agent_bot).to eq(connection.agent_bot)
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
      service = Conversations::AgentBotConditionalHumanRouteService.new(
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
    before do
      stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)
    end

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

  def make_human_available
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(agent.id.to_s => 'online')
    agent
  end

  def publish_appointment_policy
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
          link_label: 'Book a 30 minute meeting',
          website_presentation: 'calendar_embed'
        }
      }
    ).call
  end
end
