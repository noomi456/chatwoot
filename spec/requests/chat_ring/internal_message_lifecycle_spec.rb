require 'rails_helper'
require 'timeout'
require Rails.root.join('db/migrate/20260809003000_terminalize_gate_closed_chat_ring_ai_turns').to_s

module ChatRingConversationWriteBoundaryProbe
  private

  def perform_native_write
    probe = Thread.current[:chatring_message_serialization_probe]
    probe&.call(:before, nil)
    result = super
    probe&.call(:after, result)
    result
  end
end

unless ChatRing::ConversationWriteBoundary < ChatRingConversationWriteBoundaryProbe
  ChatRing::ConversationWriteBoundary.prepend(ChatRingConversationWriteBoundaryProbe)
end

RSpec.describe 'ChatRing internal Web Widget message lifecycle', type: :request do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_widget, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, email: 'visitor@example.com') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Website Assistant') }
  let(:token) do
    Widget::TokenService.new(
      payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
    ).generate_token
  end

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    inbox.update!(greeting_enabled: false, enable_email_collect: false)
    publish_and_bind_assistant!
  end

  it 'does not create or enqueue a turn while the public-response gate is closed' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)

    message = post_widget_message('What plans do you offer?')

    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
    expect(ChatRing::NativeHandlingCompletion.where(trigger_message: message)).not_to exist
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  it 'cancels an already-enqueued received turn if the gate closes before execution' do
    message = post_widget_message('What plans do you offer?')
    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)

    ChatRing::AiTurnJob.perform_now(turn.id)

    expect(turn.reload).to have_attributes(
      status: 'cancelled',
      failure_code: 'public_response_gate_closed'
    )
    expect(turn.completed_at).to be_present
  end

  it 'terminalizes every gate-closed nonterminal state without a committed outcome' do
    message = post_widget_message('What plans do you offer?')
    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    turn.update!(status: :ready_to_commit, started_at: Time.current)
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)

    ChatRing::AiTurnJob.perform_now(turn.id)

    expect(turn.reload).to have_attributes(status: 'cancelled', failure_code: 'public_response_gate_closed')
  end

  it 'reconciles a gate-closed nonterminal turn from its already committed outcome' do
    message = post_widget_message('Please connect me to a person')
    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    turn.update!(status: :ready_to_commit, started_at: Time.current)
    ChatRing::OutboundCommit.create!(
      ai_turn: turn,
      outcome_type: :handoff,
      status: :committed,
      idempotency_key: Digest::SHA256.hexdigest("gate-reconcile:#{turn.id}"),
      committed_at: Time.current
    )
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', false)

    ChatRing::AiTurnJob.perform_now(turn.id)

    expect(turn.reload).to have_attributes(status: 'handed_off', failure_code: nil)
  end

  it 'backfills an unstarted legacy received turn to cancelled' do
    message = post_widget_message('What plans do you offer?')
    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    turn.update!(native_handling_snapshot: {})

    TerminalizeGateClosedChatRingAiTurns.new.migrate(:up)

    expect(turn.reload).to have_attributes(
      status: 'cancelled',
      failure_code: 'public_response_gate_closed'
    )
    expect(turn.completed_at).to be_present
  end

  it 'creates one internally sourced turn after native handling without a webhook delivery' do
    message = post_widget_message('What plans do you offer?')
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist

    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)

    expect(turn).to be_status_received
    expect(turn.native_handling_snapshot).to include(
      'trigger_message_id' => message.id,
      'greeting_message_ids' => [],
      'email_input_message_ids' => [],
      'out_of_office_message_ids' => []
    )
    expect(turn.native_handling_snapshot.fetch('automation')).to include(
      'completed' => true,
      'matched_rule_ids' => [],
      'effects' => []
    )
    expect(ChatRing::WebhookDelivery.count).to eq(0)
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once.with(turn.id)
  end

  it 'waits for template completion when native Automation finishes first' do
    automation_finished_before_template = false
    allow(EventDispatcherJob).to receive(:perform_later).and_wrap_original do |original, event_name, timestamp, data|
      event_message = data[:message]
      if event_name == Message::MESSAGE_CREATED && event_message&.content == 'Automation wins the race'
        EventDispatcherJob.perform_now(event_name, timestamp, data)
        automation_finished_before_template = !ChatRing::AiTurn.exists?(trigger_message: event_message)
      else
        original.call(event_name, timestamp, data)
      end
    end

    message = post_widget_message('Automation wins the race')
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)

    expect(automation_finished_before_template).to be(true)
    expect(turn.native_handling_snapshot.dig('automation', 'completed')).to be(true)
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once.with(turn.id)
  end

  it 'records actual benign Automation effects without re-running the rule' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [inbox_condition],
      actions: [{ 'action_name' => 'add_label', 'action_params' => ['priority_customer'] }]
    )

    message = post_widget_message('Please label this conversation')
    expect(message.conversation.reload.label_list).not_to include('priority_customer')
    expect(AutomationRules::ConditionsFilterService).to receive(:new).once.and_call_original

    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    effect = turn.native_handling_snapshot.dig('automation', 'effects').sole

    expect(message.conversation.reload.label_list).to include('priority_customer')
    expect(effect).to include(
      'rule_id' => rule.id,
      'action_names' => ['add_label']
    )
    expect(effect.dig('before', 'labels')).not_to include('priority_customer')
    expect(effect.dig('after', 'labels')).to include('priority_customer')
  end

  it 'releases one turn when native completion is delivered more than once' do
    message = post_widget_message('Only one turn please')

    2.times { complete_automation_for(message) }

    expect(ChatRing::AiTurn.where(trigger_message: message).count).to eq(1)
    expect(ChatRing::NativeHandlingCompletion.find_by!(trigger_message: message).released_at).to be_present
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once
  end

  it 'preserves the native Widget write when template observation fails' do
    allow(ChatRing::NativeHandling::CompletionRecorder).to receive(:record_template).and_raise(ActiveRecord::ConnectionNotEstablished)

    message = post_widget_message('Native handling must survive')

    expect(message).to be_persisted
    completion = ChatRing::NativeHandlingCompletion.find_by!(trigger_message: message)
    expect(completion.template_completed_at).to be_nil
    expect(completion.released_at).to be_nil
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
  end

  it 'preserves native Automation effects when completion persistence fails' do
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [inbox_condition],
      actions: [{ 'action_name' => 'add_label', 'action_params' => ['native_effect'] }]
    )
    message = post_widget_message('Keep the native effect')
    allow(ChatRing::NativeHandling::CompletionRecorder).to receive(:record_automation).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { complete_automation_for(message) }.not_to raise_error

    expect(message.conversation.reload.label_list).to include('native_effect')
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
  end

  it 'records the native greeting and allows one AI turn afterward' do
    inbox.update!(greeting_enabled: true, greeting_message: 'Welcome to ChatRing')

    message = post_widget_message('What plans do you offer?')
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist

    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    greeting = message.conversation.messages.template.find_by!(content: 'Welcome to ChatRing')

    expect(turn).to be_status_received
    expect(turn.native_handling_snapshot.fetch('greeting_message_ids')).to eq([greeting.id])
    expect(ChatRing::AiTurnJob).to have_been_enqueued.once.with(turn.id)
  end

  it 'keeps email collection terminal on later messages while the Contact email is absent' do
    contact.update!(email: nil)
    inbox.update!(enable_email_collect: true)

    first_message = post_widget_message('I need help')
    second_message = post_widget_message('Are you there?')
    expect(ChatRing::AiTurn.where(trigger_message: [first_message, second_message])).to be_empty

    complete_automation_for(first_message)
    complete_automation_for(second_message)
    first_turn = ChatRing::AiTurn.find_by!(trigger_message: first_message)
    second_turn = ChatRing::AiTurn.find_by!(trigger_message: second_message)

    expect(first_turn).to be_status_ineligible
    expect(first_turn.decision_type).to eq('native_email_collection')
    expect(second_turn).to be_status_ineligible
    expect(second_turn.decision_type).to eq('native_email_collection')
    expect(second_turn.native_handling_snapshot.fetch('email_collection_required')).to be(true)
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  it 'records native out-of-office handling and does not enqueue inference' do
    inbox.update!(working_hours_enabled: true, out_of_office_message: 'We are currently closed')
    inbox.working_hours.find_by!(day_of_week: Time.zone.today.wday).update!(closed_all_day: true, open_all_day: false)

    message = post_widget_message('What plans do you offer?')
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist

    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)
    out_of_office = message.conversation.messages.template.find_by!(content: 'We are currently closed')

    expect(turn).to be_status_ineligible
    expect(turn.decision_type).to eq('native_out_of_office')
    expect(turn.native_handling_snapshot.fetch('out_of_office_message_ids')).to eq([out_of_office.id])
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  it 'does not affect an unbound native Web Widget inbox' do
    binding = workspace.inbox_assistant_bindings.find_by!(chatwoot_inbox_id: inbox.id)
    binding.ai_turns.destroy_all
    binding.destroy!
    AgentBotInbox.where(inbox_id: inbox.id).delete_all

    message = post_widget_message('Hello')
    complete_automation_for(message)

    expect(message).to be_persisted
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
    expect(ChatRing::NativeHandlingCompletion.where(trigger_message: message)).not_to exist
  end

  it 'does not adopt a message that committed before the first Assistant binding' do
    current_binding = workspace.inbox_assistant_bindings.find_by!(chatwoot_inbox_id: inbox.id)
    current_binding.update!(status: :inactive)
    AgentBotInbox.where(inbox_id: inbox.id).delete_all

    message = post_widget_message('This message predates the binding')
    AgentBotInbox.create!(inbox: inbox, agent_bot: assistant.agent_bot_connection.agent_bot, status: :active)
    current_binding.update!(status: :active)
    complete_automation_for(message)

    expect(ChatRing::NativeHandlingCompletion.where(trigger_message: message)).not_to exist
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist
  end

  it 'fails closed at scheduling when a conflicting automation bypasses binding validation' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      active: false,
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Automation reply'] }]
    )
    rule.update_columns(active: true, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    clear_enqueued_jobs

    message = post_widget_message('Can the Assistant answer this?')
    expect(ChatRing::AiTurn.where(trigger_message: message)).not_to exist

    complete_automation_for(message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: message)

    expect(turn).to be_status_ineligible
    expect(turn.decision_type).to eq('automation_conflict')
    expect(ChatRing::AiTurnJob).not_to have_been_enqueued
  end

  # The production controllers invoke this boundary around their native Message writers.
  it 'rejects an old AI reply when a real Widget writer wins the serialization boundary' do
    trigger_message = post_widget_message('What plans do you offer?')
    turn = ready_turn_for(trigger_message)
    service = conditional_service_for(turn)
    writer_inside_boundary = Queue.new
    release_writer = Queue.new
    writer_thread = run_writer_with_probe(writer_inside_boundary, 'One more question', phase: :after, release: release_writer) do
      widget_session.post(widget_messages_path, **widget_request('One more question'))
    end
    wait_for(writer_inside_boundary)
    ai_thread = run_in_thread do
      service.perform
    rescue StandardError => e
      e
    end
    release_writer << true
    writer_thread.value
    error = ai_thread.value

    expect(error).to be_a(Conversations::AgentBotConditionalCommitService::PreconditionFailed)
    expect(error.code).to eq('newer_customer_message')
    expect(trigger_message.conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
  end

  it 'rejects an old AI reply when a real dashboard public-reply writer completes native takeover first' do
    trigger_message = post_widget_message('What plans do you offer?')
    turn = ready_turn_for(trigger_message)
    service = conditional_service_for(turn)
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: agent)
    writer_inside_boundary = Queue.new
    release_writer = Queue.new
    path = api_v1_account_conversation_messages_path(
      account_id: account.id,
      conversation_id: trigger_message.conversation.display_id
    )
    request = {
      params: { content: 'I will take this', private: false },
      headers: agent.create_new_auth_token,
      as: :json
    }

    writer_thread = run_writer_with_probe(writer_inside_boundary, 'I will take this', phase: :after, release: release_writer) do
      dashboard_session.post(path, **request)
    end
    wait_for(writer_inside_boundary)
    ai_thread = run_in_thread do
      service.perform
    rescue StandardError => e
      e
    end
    release_writer << true
    writer_thread.value
    error = ai_thread.value

    expect(error).to be_a(Conversations::AgentBotConditionalCommitService::PreconditionFailed)
    expect(error.code).to eq('newer_human_reply')
    expect(trigger_message.conversation.reload).to have_attributes(status: 'open', assignee: agent, assignee_agent_bot: nil)
    expect(trigger_message.conversation.messages.outgoing.where(sender: turn.expected_agent_bot)).to be_empty
  end

  it 'rejects an old handoff when a real Widget writer wins the serialization boundary' do
    trigger_message = post_widget_message('What plans do you offer?')
    turn = ready_turn_for(trigger_message, outcome_type: :handoff)
    service = handoff_service_for(turn)
    writer_inside_boundary = Queue.new
    release_writer = Queue.new
    writer_thread = run_writer_with_probe(writer_inside_boundary, 'One more question before handoff',
                                          phase: :after, release: release_writer) do
      widget_session.post(widget_messages_path, **widget_request('One more question before handoff'))
    end
    wait_for(writer_inside_boundary)
    handoff_thread = run_in_thread do
      service.perform
    rescue StandardError => e
      e
    end
    release_writer << true
    writer_thread.value
    error = handoff_thread.value

    expect(error).to be_a(Conversations::AgentBotConditionalCommitService::PreconditionFailed)
    expect(error.code).to eq('newer_customer_message')
    expect(turn.outbound_commit.reload).to have_attributes(status: 'rejected', failure_code: 'newer_customer_message')
    expect(trigger_message.conversation.reload.assignee_agent_bot).to eq(turn.expected_agent_bot)
  end

  private

  def publish_and_bind_assistant!
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { instructions: 'Answer from evidence.', identity: { name: assistant.name } }
    ).call
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end

  def post_widget_message(content)
    post api_v1_widget_messages_url,
         params: {
           website_token: channel.website_token,
           message: { content: content, timestamp: Time.current }
         },
         headers: { 'X-Auth-Token' => token },
         as: :json

    expect(response).to have_http_status(:success)
    Message.find(response.parsed_body.fetch('id'))
  end

  def ready_turn_for(trigger_message, outcome_type: :reply)
    complete_automation_for(trigger_message) unless ChatRing::AiTurn.exists?(trigger_message: trigger_message)
    turn = ChatRing::AiTurn.find_by!(trigger_message: trigger_message)
    turn.update!(
      status: :ready_to_commit,
      decision_type: outcome_type,
      decision_payload: {
        'decision_type' => outcome_type.to_s,
        'response_text' => outcome_type == :reply ? 'Our plans are...' : '',
        'reason_code' => outcome_type == :reply ? 'answered' : 'human_requested',
        'evidence_ids' => outcome_type == :reply ? ['evidence-1'] : []
      }
    )
    ChatRing::OutboundCommit.create!(
      ai_turn: turn,
      idempotency_key: Digest::SHA256.hexdigest("chatring:#{outcome_type}:#{workspace.id}:#{turn.id}"),
      outcome_type: outcome_type
    )
    turn
  end

  def conditional_service_for(turn)
    Conversations::AgentBotConditionalCommitService.new(
      conversation: turn.conversation,
      agent_bot: turn.expected_agent_bot,
      expected_agent_bot_id: turn.expected_agent_bot_id,
      responding_to_message_id: turn.trigger_message_id,
      idempotency_key: turn.outbound_commit.idempotency_key,
      message: { content: turn.decision_payload.fetch('response_text'), content_type: 'text' }
    )
  end

  def handoff_service_for(turn)
    Conversations::AgentBotConditionalHandoffService.new(turn: turn, outbound_commit: turn.outbound_commit)
  end

  def widget_session
    @widget_session ||= ActionDispatch::Integration::Session.new(Rails.application)
  end

  def dashboard_session
    @dashboard_session ||= ActionDispatch::Integration::Session.new(Rails.application)
  end

  def widget_messages_path
    Rails.application.routes.url_helpers.api_v1_widget_messages_path
  end

  def widget_request(content)
    {
      params: {
        website_token: channel.website_token,
        message: { content: content, timestamp: Time.current }
      },
      headers: { 'X-Auth-Token' => token },
      as: :json
    }
  end

  def run_in_thread(&)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  def run_writer_with_probe(queue, content, phase:, release: nil)
    run_in_thread do
      Thread.current[:chatring_message_serialization_probe] = lambda do |observed_phase, message|
        next unless observed_phase == phase && message.content == content

        queue << true
        ActiveSupport::Dependencies.interlock.permit_concurrent_loads { release.pop } if release
      end
      yield
    ensure
      Thread.current[:chatring_message_serialization_probe] = nil
    end
  end

  def wait_for(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def complete_automation_for(message)
    EventDispatcherJob.perform_now(
      Message::MESSAGE_CREATED,
      message.created_at,
      { message: message, performed_by: nil }
    )
  end

  def inbox_condition
    {
      'values' => [inbox.id],
      'attribute_key' => 'inbox_id',
      'query_operator' => nil,
      'filter_operator' => 'equal_to'
    }
  end
end
