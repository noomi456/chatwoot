# frozen_string_literal: true

# The proof driver is intentionally a single disposable executable so none of its
# orchestration becomes application lifecycle code.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

class ChatRingWebWidgetProof
  class Failure < StandardError; end

  BindingFixture = Data.define(:assistant, :connection, :channel, :inbox, :contact, :contact_inbox, :token)

  WAIT_TIMEOUT = 300
  POLL_INTERVAL = 0.25
  AI_INSERT_ADVISORY_LOCK = 7_260_813

  def initialize
    raise Failure, 'proof driver requires an isolated runtime' unless ENV['PROOF_ISOLATED_RUN'] == 'true'
    raise Failure, 'proof driver requires the public gate override' unless ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY
    raise Failure, 'proof driver requires internal runtime mode' if ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED

    @run_id = ENV.fetch('PROOF_RUN_ID')
    @app_url = URI(ENV.fetch('PROOF_APP_URL', 'http://rails:3000'))
    @state_dir = ENV.fetch('PROOF_STATE_DIR', '/proof-state')
    @results = {}
    FileUtils.mkdir_p(state_dir)
  end

  def call
    setup!
    run_first_binding_linearization!
    run_supported_lifecycle!
    run_committed_outcome_recovery!
    run_unsupported_handoff!
    run_native_template_arbitration!
    run_concurrency_ten!
    run_human_takeover_race!
    run_ai_first_serialization_race!
    run_provider_failure_recovery!
    run_unbound_widget_regression!
    run_knowledge_pin_cleanup!
    record_runtime_contract!
    write_result!
  ensure
    cleanup_provider! unless ENV['PROOF_KEEP_PROVIDER_DATA'] == 'true'
  end

  private

  attr_reader :run_id, :app_url, :state_dir, :results, :account, :workspace, :knowledge_base, :knowledge_index,
              :channel, :inbox, :assistant, :assistant_version, :connection, :binding, :human

  def setup!
    @account = Account.create!(name: "ChatRing proof #{run_id}", status: 'active')
    @workspace = ChatRing::Workspace.for_account!(account)
    @knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    @channel = Channel::WebWidget.create!(account: account, website_url: 'https://proof.invalid')
    @inbox = Inbox.create!(
      account: account,
      channel: channel,
      name: "Proof Widget #{run_id}",
      greeting_enabled: false,
      enable_email_collect: false,
      working_hours_enabled: false
    )
    @human = create_human!
    create_knowledge!
    create_assistant!
    wait_for_knowledge!
    assert!(connection.agent_bot.reload.outgoing_url.blank?, 'managed AgentBot acquired a self-webhook')
    assert!(ChatRing::WebhookDelivery.where(workspace: workspace).none?, 'setup created a WebhookDelivery')
  end

  def create_human!
    user = User.new(
      name: "Proof Agent #{run_id}",
      email: "proof-agent-#{run_id}@example.invalid",
      password: "Proof-#{SecureRandom.hex(12)}-1!",
      availability: :online
    )
    user.skip_confirmation!
    user.save!
    AccountUser.create!(account: account, user: user, role: :administrator)
    InboxMember.create!(inbox: inbox, user: user)
    user
  end

  def create_knowledge!
    source_url = "https://proof.invalid/#{run_id}/pricing"
    source = knowledge_base.website_sources.create!(
      root_url: source_url,
      canonical_origin: 'https://proof.invalid',
      source_type: 'webpage',
      status: 'available',
      mapped_manifest: [{ 'url' => source_url, 'status' => 'selected' }]
    )
    markdown = <<~MARKDOWN
      # ChatRing pricing

      ## Growth plan

      ChatRing Growth costs 49 US dollars per month and includes the Web Widget,
      shared Training Materials, and human handoff in one Chatwoot conversation.

      ## Scale plan

      ChatRing Scale costs 99 US dollars per month and adds advanced routing and
      higher conversation capacity.
    MARKDOWN
    digest = Digest::SHA256.hexdigest(markdown)
    knowledge_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: source_url,
      public_url: source_url,
      title: 'ChatRing pricing',
      markdown: markdown,
      content_hash: digest,
      extracted_at: Time.current,
      status: 'processing',
      authority_class: 'structured_commercial',
      metadata: {},
      risk_flags: []
    )
    ChatRing::Knowledge::IndexBuilder.enqueue!(knowledge_base)
  end

  def create_assistant!
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    @assistant = ChatRing::Assistant.create!(workspace: workspace, name: "Sales Assistant #{run_id}")
    @assistant_version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: {
        identity: { 'name' => 'ChatRing Sales Assistant' },
        goals: ['Answer grounded product and pricing questions.'],
        instructions: 'Use supplied evidence only. Keep the answer concise.',
        response_guidelines: ['Cite the supplied evidence ID.'],
        guardrails: ['Never invent personal or business facts.'],
        handoff_policy: {
          'on_insufficient_evidence' => 'handoff',
          'on_provider_failure' => 'handoff'
        },
        llm_provider: 'openai',
        llm_model: 'gpt-5.4'
      }
    ).call
    @connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    @binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
  end

  def wait_for_knowledge!
    wait_for('DocsGPT index activation', timeout: 600) do
      @knowledge_index = knowledge_base.reload.active_knowledge_index
      knowledge_index&.status == 'active'
    end
    assert!(knowledge_index.documents.exists?(provider_status: 'ready'), 'active index has no ready provider document')
  end

  def run_first_binding_linearization!
    outcomes = {}
    %i[conversations messages].each do |endpoint|
      outcomes["#{endpoint}_writer_first"] = run_writer_before_first_binding!(endpoint)
      outcomes["#{endpoint}_binding_first"] = run_binding_before_first_writer!(endpoint)
    end
    results[:first_binding_linearization] = outcomes
  end

  def run_writer_before_first_binding!(endpoint)
    fixture = create_binding_fixture!("#{endpoint}-writer-first")
    lock_connection, lock_pid = checkout_record_lock!('accounts', account.id)
    binder = start_binding(fixture)
    binder_pid = wait_for_blocked_backend!(lock_pid, 'accounts')
    message = post_first_widget(fixture, endpoint, "First native message before binding #{run_id}")
    wait_for('pre-binding native Automation completion') do
      message.conversation.reload.label_list.include?(fixture_label(fixture))
    end
    release_record_lock!(lock_connection)
    lock_connection = nil
    binder.value

    assert!(ChatRing::NativeHandlingCompletion.where(trigger_message: message).none?,
            'first Message committed before binding was adopted by ChatRing')
    assert!(ChatRing::AiTurn.where(trigger_message: message).none?,
            'first Message committed before binding created an AITurn')
    assert!(message.conversation.reload.assignee_agent_bot_id.nil?,
            'first Conversation committed before binding acquired an AgentBot later')
    { writer_won: true, binder_waiter_pid: binder_pid, adopted_turns: 0 }
  ensure
    release_record_lock!(lock_connection) if defined?(lock_connection) && lock_connection
  end

  def run_binding_before_first_writer!(endpoint)
    fixture = create_binding_fixture!("#{endpoint}-binding-first")
    lock_connection, lock_pid = checkout_record_lock!('inboxes', fixture.inbox.id)
    binder = start_binding(fixture)
    binder_pid = wait_for_blocked_backend!(lock_pid, 'inboxes')
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        post_first_widget(
          fixture,
          endpoint,
          "[[PROOF_LOCAL_REPLY]] First managed message after binding #{run_id}"
        )
      end
    end
    writer_pid = wait_for_blocked_backend!(lock_pid, 'inboxes', exclude_pids: [binder_pid])
    release_record_lock!(lock_connection)
    lock_connection = nil
    binder.value
    message = writer.value
    turn = wait_for_terminal_turn(message)

    assert!(message.conversation.reload.assignee_agent_bot_id == fixture.connection.agent_bot_id,
            'binding-first Conversation did not retain the managed native AgentBot')
    assert!(ChatRing::NativeHandlingCompletion.where(trigger_message: message).one?,
            'binding-first Message did not create exactly one completion record')
    assert!(turn.status_committed?, "binding-first turn ended as #{turn.status}")
    { binding_won: true, binder_waiter_pid: binder_pid, writer_waiter_pid: writer_pid, turns: 1 }
  ensure
    release_record_lock!(lock_connection) if defined?(lock_connection) && lock_connection
  end

  def run_supported_lifecycle!
    visitor = create_visitor(email: "supported-#{run_id}@example.invalid")
    cable_messages = Queue.new
    cable_callback = subscribe_to_action_cable!(visitor.fetch(:contact_inbox), cable_messages)
    message = post_widget(visitor, "What pricing plans does ChatRing offer? proof #{run_id}")
    turn = wait_for_terminal_turn(message)
    outgoing = wait_for_bot_message(turn)
    attempt = turn.attempts.order(:attempt_number).last

    assert!(turn.status_committed?, "supported turn ended as #{turn.status}")
    assert!(turn.evidence.exists?, 'supported turn has no persisted evidence')
    assert!(turn.knowledge_index_id == knowledge_index.id, 'supported turn did not pin the active index')
    assert!(attempt&.status_succeeded?, 'supported turn has no successful provider attempt')
    assert!(attempt.model == 'gpt-5.4', "supported turn used #{attempt.model.inspect}")
    assert!(attempt.input_tokens.to_i.positive? && attempt.output_tokens.to_i.positive?, 'provider token accounting is empty')
    assert!(turn.outbound_commit&.status_committed?, 'supported reply has no committed outbound ledger')
    assert!(outgoing.sender == connection.agent_bot, 'supported reply is not an ordinary managed AgentBot Message')
    assert!(ChatRing::AiTurn.where(trigger_message: outgoing).none?, 'AI reply recursively created an AITurn')
    citations = outgoing.content_attributes.fetch('chatring_citations')
    assert!(citations.any? { |citation| citation['url']&.start_with?('https://proof.invalid/') },
            'supported reply has no visitor-safe citation')
    assert_widget_refresh_includes_citations!(visitor, outgoing, citations)
    assert_action_cable_citations!(cable_messages, outgoing, turn, citations)
    @supported_turn = turn
    @supported_outgoing = outgoing

    results[:supported] = {
      turn_status: turn.status,
      evidence_count: turn.evidence.count,
      attempt_model: attempt.model,
      visitor_citations: citations.size,
      input_tokens_recorded: attempt.input_tokens.to_i.positive?,
      output_tokens_recorded: attempt.output_tokens.to_i.positive?,
      outbound_messages: turn.conversation.messages.outgoing.where(sender: connection.agent_bot).count
    }
  ensure
    unsubscribe_from_action_cable(visitor&.dig(:contact_inbox), cable_callback)
  end

  def run_committed_outcome_recovery!
    original_message_id = @supported_outgoing.id
    original_message_count = @supported_turn.conversation.messages.where(source_id: @supported_outgoing.source_id).count
    @supported_turn.update!(status: :ready_to_commit, completed_at: nil)
    job = ChatRing::AiTurnRecoverySweepJob.perform_later
    assert!(job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?,
            'recovery sweep could not be queued')
    wait_for('committed outcome recovery') { @supported_turn.reload.status_committed? }

    recovered_commit = @supported_turn.outbound_commit.reload
    assert!(recovered_commit.message_id == original_message_id, 'recovery changed the committed native Message')
    assert!(
      @supported_turn.conversation.messages.where(source_id: @supported_outgoing.source_id).count == original_message_count,
      'recovery duplicated the committed native Message'
    )
    results[:committed_outcome_recovery] = {
      recovered_same_message: true,
      message_count: original_message_count
    }
  end

  def run_unsupported_handoff!
    visitor = create_visitor(email: "unsupported-#{run_id}@example.invalid")
    message = post_widget(visitor, "What is the founder's mother's passport number? proof #{run_id}")
    turn = wait_for_terminal_turn(message)
    conversation = turn.conversation.reload

    assert!(turn.status_handed_off?, "unsupported turn ended as #{turn.status}")
    assert!(turn.outbound_commit&.status_committed?, 'unsupported handoff has no committed ledger')
    assert!(turn.outbound_commit.outcome_type_handoff?, 'unsupported outcome is not handoff')
    assert!(conversation.open?, 'native handoff did not open the Conversation')
    assert!(conversation.assignee_agent_bot_id.nil?, 'native handoff did not clear AgentBot ownership')
    assert!(conversation.messages.outgoing.where(sender: connection.agent_bot).none?, 'unsupported turn fabricated a public reply')

    results[:unsupported] = {
      turn_status: turn.status,
      outcome_type: turn.outbound_commit.outcome_type,
      conversation_status: conversation.status,
      managed_bot_cleared: conversation.assignee_agent_bot_id.nil?,
      fabricated_reply_count: 0
    }
  end

  def run_native_template_arbitration!
    run_greeting_case!
    run_email_collection_case!
    run_out_of_office_case!
    run_benign_automation_case!
    run_public_automation_case!
  ensure
    inbox.update!(
      greeting_enabled: false,
      enable_email_collect: false,
      working_hours_enabled: false
    )
  end

  def run_benign_automation_case!
    rule = create_incoming_automation!(
      name: "Proof benign Automation #{run_id}",
      actions: [{ 'action_name' => 'add_label', 'action_params' => ["proof-benign-#{run_id}"] }]
    )
    visitor = create_visitor(email: "benign-automation-#{run_id}@example.invalid")
    message = post_widget(visitor, "[[PROOF_LOCAL_REPLY]] What pricing plans are available? benign #{run_id}")
    turn = wait_for_terminal_turn(message)
    wait_for_bot_message(turn)

    assert!(turn.status_committed?, "benign Automation turn ended as #{turn.status}")
    assert!(turn.conversation.reload.label_list.include?("proof-benign-#{run_id}"),
            'benign native Automation label was not applied')
    results[:benign_automation] = { native_label_applied: true, turn_status: turn.status }
  ensure
    rule&.destroy!
  end

  def run_public_automation_case!
    response_text = "Native Automation answered proof #{run_id}"
    rule = create_incoming_automation!(
      name: "Proof public Automation #{run_id}",
      actions: [{ 'action_name' => 'send_message', 'action_params' => [response_text] }]
    )
    visitor = create_visitor(email: "public-automation-#{run_id}@example.invalid")
    message = post_widget(visitor, "Automation should answer this proof #{run_id}")
    turn = wait_for_turn(message)
    wait_for('public Automation terminalization') { turn.reload.status_ineligible? }
    native_responses = turn.conversation.messages.where(content: response_text, private: false)

    assert!(turn.decision_type == 'native_automation_response',
            "public Automation decision is #{turn.decision_type.inspect}")
    assert!(native_responses.one?, "public Automation produced #{native_responses.count} responses")
    assert!(turn.attempts.none?, 'public Automation response started inference')
    assert!(turn.outbound_commit.nil?, 'public Automation response created an AI outbound ledger')
    results[:public_automation] = { native_responses: 1, inference_attempts: 0 }
  ensure
    rule&.destroy!
  end

  def run_greeting_case!
    inbox.update!(greeting_enabled: true, greeting_message: "Welcome proof #{run_id}", enable_email_collect: false)
    visitor = create_visitor(email: "greeting-#{run_id}@example.invalid")
    message = post_widget(visitor, "[[PROOF_LOCAL_REPLY]] What pricing plans does ChatRing offer? greeting proof #{run_id}")
    turn = wait_for_terminal_turn(message)
    wait_for_bot_message(turn)
    greeting_count = turn.conversation.messages.template.where(content: "Welcome proof #{run_id}").count
    assert!(greeting_count == 1, "native greeting count is #{greeting_count}")
    assert!(turn.status_committed?, "greeting turn ended as #{turn.status}")
    results[:greeting] = { native_greetings: greeting_count, turn_status: turn.status }
    inbox.update!(greeting_enabled: false)
  end

  def run_email_collection_case!
    inbox.update!(enable_email_collect: true)
    visitor = create_visitor(email: nil)
    message = post_widget(visitor, "I need pricing help email proof #{run_id}")
    turn = wait_for_turn(message)
    wait_for('email collection terminalization') { turn.reload.status_ineligible? }
    email_inputs = turn.conversation.messages.template.where(content_type: :input_email).count
    assert!(turn.decision_type == 'native_email_collection', "email collection decision is #{turn.decision_type.inspect}")
    assert!(email_inputs == 1, "native email input count is #{email_inputs}")
    assert!(turn.attempts.none?, 'email collection started inference')
    assert!(turn.outbound_commit.nil?, 'email collection created an outbound AI ledger')
    results[:email_collection] = { native_email_inputs: email_inputs, inference_attempts: 0 }
    inbox.update!(enable_email_collect: false)
  end

  def run_out_of_office_case!
    inbox.update!(working_hours_enabled: true, out_of_office_message: "We are closed proof #{run_id}")
    inbox.working_hours.find_by!(day_of_week: Time.zone.today.wday).update!(closed_all_day: true, open_all_day: false)
    visitor = create_visitor(email: "closed-#{run_id}@example.invalid")
    message = post_widget(visitor, "What pricing plans does ChatRing offer? closed proof #{run_id}")
    turn = wait_for_turn(message)
    wait_for('out-of-office terminalization') { turn.reload.status_ineligible? }
    native_messages = turn.conversation.messages.template.where(content: "We are closed proof #{run_id}").count
    assert!(turn.decision_type == 'native_out_of_office', "out-of-office decision is #{turn.decision_type.inspect}")
    assert!(native_messages == 1, "native out-of-office count is #{native_messages}")
    assert!(turn.attempts.none?, 'out-of-office handling started inference')
    assert!(turn.outbound_commit.nil?, 'out-of-office handling created an outbound AI ledger')
    results[:out_of_office] = { native_messages: native_messages, inference_attempts: 0 }
  end

  def run_concurrency_ten!
    inbox.update!(working_hours_enabled: false, greeting_enabled: false, enable_email_collect: false)
    visitor = create_visitor(email: "concurrency-#{run_id}@example.invalid", conversation: true)
    reset_provider_barrier!
    responses = Queue.new
    threads = Array.new(10) do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          responses << post_widget(
            visitor,
            "[[PROOF_HOLD]] [[PROOF_LOCAL_REPLY]] What pricing plans are available? burst #{run_id}-#{index}"
          )
        rescue StandardError => e
          responses << e
        end
      end
    end
    threads.each(&:join)
    posted = Array.new(10) { responses.pop }
    errors = posted.grep(StandardError)
    raise errors.first if errors.any?

    wait_for('at least one held provider request', timeout: 90) { File.exist?(File.join(state_dir, 'provider_entered')) }
    FileUtils.touch(File.join(state_dir, 'release_provider'))
    messages = posted.sort_by(&:id)
    turns = wait_for('ten AITurn audit records') do
      records = ChatRing::AiTurn.where(trigger_message_id: messages.map(&:id)).order(:trigger_message_id).to_a
      records if records.size == 10
    end
    wait_for('concurrency turns to become terminal', timeout: 300) do
      turns.none? { |turn| ChatRing::AiTurn::NONTERMINAL_STATUSES.include?(turn.reload.status) }
    end
    committed = turns.select(&:status_committed?)
    bot_messages = visitor.fetch(:conversation).reload.messages.outgoing.where(sender: connection.agent_bot)
    assert!(committed.size == 1, "concurrency produced #{committed.size} committed turns instead of one")
    assert!(bot_messages.count == 1, "concurrency produced #{bot_messages.count} bot replies instead of one")
    assert!(committed.first.trigger_message_id == messages.last.id,
            'a stale burst turn committed instead of the newest turn')
    assert!(turns.none? { |turn| ChatRing::AiTurn::NONTERMINAL_STATUSES.include?(turn.status) }, 'burst left a nonterminal turn')

    results[:concurrency_ten] = {
      incoming_messages: messages.size,
      committed_turns: committed.size,
      bot_messages: bot_messages.count,
      nonterminal_turns: 0
    }
  ensure
    FileUtils.touch(File.join(state_dir, 'release_provider'))
  end

  def run_human_takeover_race!
    visitor = create_visitor(email: "takeover-#{run_id}@example.invalid", conversation: true)
    reset_provider_barrier!
    message = post_widget(visitor, "[[PROOF_HOLD]] [[PROOF_LOCAL_REPLY]] Explain pricing before takeover #{run_id}")
    turn = wait_for_turn(message)
    wait_for_provider_barrier!

    human_message = post_dashboard_reply(visitor.fetch(:conversation), "I will take this conversation #{run_id}")
    FileUtils.touch(File.join(state_dir, 'release_provider'))
    wait_for('human takeover turn terminalization') { ChatRing::AiTurn::NONTERMINAL_STATUSES.exclude?(turn.reload.status) }
    conversation = visitor.fetch(:conversation).reload

    assert!(turn.status_superseded?, "human takeover turn ended as #{turn.status}")
    assert!(turn.failure_code == 'newer_human_reply', "human takeover failure is #{turn.failure_code.inspect}")
    assert!(conversation.open? && conversation.assignee == human && conversation.assignee_agent_bot_id.nil?,
            'native human takeover did not become authoritative')
    assert!(conversation.messages.exists?(id: human_message.id), 'native dashboard Message was not persisted')
    assert!(conversation.messages.outgoing.where(sender: connection.agent_bot).none?, 'late AI reply survived human takeover')
    results[:human_takeover] = { turn_status: turn.status, native_owner: 'human', late_ai_replies: 0 }
  ensure
    FileUtils.touch(File.join(state_dir, 'release_provider'))
  end

  def run_ai_first_serialization_race!
    results[:ai_first_serialization] = {
      customer_writer: run_ai_first_serialization_case!(:customer),
      human_writer: run_ai_first_serialization_case!(:human)
    }
  end

  def run_ai_first_serialization_case!(writer_kind)
    visitor = create_visitor(email: "ai-first-#{writer_kind}-#{run_id}@example.invalid", conversation: true)
    reset_provider_barrier!
    install_ai_insert_barrier!
    lock_connection = checkout_ai_insert_lock!
    trigger = post_widget(
      visitor,
      "[[PROOF_HOLD]] [[PROOF_LOCAL_REPLY]] Explain pricing before #{writer_kind} writer #{run_id}"
    )
    turn = wait_for_turn(trigger)
    wait_for_provider_barrier!
    FileUtils.touch(File.join(state_dir, 'release_provider'))
    ai_insert_pid = wait_for_ai_insert_lock!

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        if writer_kind == :human
          post_dashboard_reply(visitor.fetch(:conversation), "Human takes over after AI commit #{run_id}")
        else
          post_widget(visitor, "[[PROOF_LOCAL_REPLY]] One follow-up after the reply #{run_id}")
        end
      end
    end
    writer_pid = wait_for_native_writer_blocked_by!(ai_insert_pid)
    assert!(writer.alive?, "#{writer_kind} writer completed while the guarded AI insert held native locks")
    duplicate_jobs = if writer_kind == :customer
                       Array.new(9) { ChatRing::OutboundCommitJob.perform_later(turn.id) }
                     else
                       []
                     end
    assert!(duplicate_jobs.all? { |job| job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued? },
            'duplicate commit deliveries could not all be queued')
    release_ai_insert_lock!(lock_connection)
    lock_connection = nil
    writer_message = writer.value
    ai_message = wait_for_bot_message(wait_for_terminal_turn(trigger))

    assert!(turn.reload.status_committed?, "AI-first turn ended as #{turn.status}")
    assert!(turn.conversation.messages.where(source_id: ai_message.source_id).one?,
            'duplicate commit deliveries created more than one native Message')
    assert!(ai_message.id < writer_message.id, "competing #{writer_kind} Message committed before the guarded AI insert")
    if writer_kind == :human
      conversation = turn.conversation.reload
      assert!(conversation.open? && conversation.assignee == human && conversation.assignee_agent_bot_id.nil?,
              'AI-first dashboard reply did not complete native human takeover')
      assert!(ChatRing::AiTurn.where(trigger_message: writer_message).none?, 'human reply created an AITurn')
    else
      follow_up_turn = wait_for_terminal_turn(writer_message)
      assert!(follow_up_turn.status_committed?, "post-AI follow-up ended as #{follow_up_turn.status}")
    end
    {
      ai_message_id: ai_message.id,
      later_writer_message_id: writer_message.id,
      writer_backend_pid: writer_pid,
      writer_blocked_until_ai_commit: true,
      duplicate_commit_deliveries: duplicate_jobs.size + 1,
      committed_messages: 1
    }
  ensure
    release_ai_insert_lock!(lock_connection) if defined?(lock_connection) && lock_connection
    remove_ai_insert_barrier!
    FileUtils.touch(File.join(state_dir, 'release_provider'))
  end

  def run_provider_failure_recovery!
    visitor = create_visitor(email: "failure-#{run_id}@example.invalid")
    message = post_widget(visitor, "[[PROOF_FAIL_503]] What pricing plans are available? failure #{run_id}")
    turn = wait_for_terminal_turn(message)
    conversation = turn.conversation.reload

    assert!(turn.status_handed_off?, "provider failure turn ended as #{turn.status}")
    assert!(turn.attempts.count == ChatRing::AiTurn::MAX_PROVIDER_ATTEMPTS,
            "provider failure created #{turn.attempts.count} attempts")
    assert!(turn.attempts.status_running.none?, 'provider failure left a running attempt')
    assert!(turn.outbound_commit&.status_committed? && turn.outbound_commit.outcome_type_handoff?,
            'provider failure did not commit one native fallback handoff')
    assert!(conversation.open? && conversation.assignee_agent_bot_id.nil?, 'fallback did not use native handoff state')
    results[:provider_failure] = {
      attempts: turn.attempts.count,
      turn_status: turn.status,
      outcome_type: turn.outbound_commit.outcome_type
    }
  end

  def run_unbound_widget_regression!
    native_channel = Channel::WebWidget.create!(account: account, website_url: 'https://unbound-proof.invalid')
    native_inbox = Inbox.create!(account: account, channel: native_channel, name: "Unbound Widget #{run_id}")
    native_contact = Contact.create!(account: account, name: 'Unbound visitor')
    native_contact_inbox = ContactInbox.create!(
      contact: native_contact,
      inbox: native_inbox,
      source_id: "unbound-proof-#{SecureRandom.uuid}"
    )
    native_token = Widget::TokenService.new(
      payload: { source_id: native_contact_inbox.source_id, inbox_id: native_inbox.id }
    ).generate_token
    response = post_json(
      '/api/v1/widget/conversations',
      {
        website_token: native_channel.website_token,
        contact: { name: native_contact.name },
        message: { content: 'Ordinary Chatwoot Widget message', timestamp: Time.current.to_i }
      },
      'X-Auth-Token' => native_token
    )
    assert!(response.is_a?(Net::HTTPSuccess), "unbound Widget POST failed with HTTP #{response.code}")
    message = Message.find(JSON.parse(response.body).fetch('messages').first.fetch('id'))

    assert!(ChatRing::NativeHandlingCompletion.where(trigger_message: message).none?,
            'unbound Widget created a ChatRing completion record')
    assert!(ChatRing::AiTurn.where(trigger_message: message).none?, 'unbound Widget created an AITurn')
    assert!(message.conversation.assignee_agent_bot_id.nil?, 'unbound Widget acquired a managed AgentBot')
    results[:unbound_widget] = { native_message_persisted: true, chatring_turns: 0, managed_bot: false }
  end

  def run_knowledge_pin_cleanup!
    visitor = create_visitor(email: "pin-#{run_id}@example.invalid")
    reset_provider_barrier!
    message = post_widget(visitor, "[[PROOF_HOLD]] [[PROOF_LOCAL_REPLY]] Explain pricing pin #{run_id}")
    turn = wait_for_turn(message)
    wait_for_provider_barrier!
    wait_for('turn to pin the active KnowledgeIndex') do
      turn.reload.knowledge_index_id == knowledge_index.id && turn.status_running?
    end
    cleanup = retire_and_schedule_pinned_index!
    wait_for('queued cleanup to observe the nonterminal pin') do
      cleanup.reload
      cleanup if cleanup.status == 'pending' && cleanup.last_error == 'provider index is pinned by a nonterminal AI turn'
    end
    assert!(cleanup.status == 'pending', 'pinned cleanup did not remain pending')
    assert!(cleanup.last_error == 'provider index is pinned by a nonterminal AI turn',
            "pinned cleanup reason is #{cleanup.last_error.inspect}")

    FileUtils.touch(File.join(state_dir, 'release_provider'))
    wait_for_terminal_turn(message)
    cleanup.update!(eligible_at: Time.current)
    assert!(ChatRing::Knowledge::ProviderCleanupScheduler.enqueue_cleanup!(cleanup),
            'unpinned cleanup could not be re-enqueued')
    wait_for('queued cleanup to delete the unpinned provider source') do
      cleanup.reload
      cleanup if cleanup.status == 'succeeded'
    end
    results[:knowledge_pin] = { deferred_while_running: true, cleanup_status_after_turn: cleanup.status }
  ensure
    FileUtils.touch(File.join(state_dir, 'release_provider'))
  end

  def record_runtime_contract!
    assert!(ChatRing::WebhookDelivery.where(workspace: workspace).none?, 'internal proof created a WebhookDelivery')
    assert!(connection.agent_bot.reload.outgoing_url.blank?, 'managed AgentBot self-webhook was restored')
    assert!(ChatRing::AiTurn.nonterminal.where(workspace: workspace).none?, 'proof left a nonterminal AITurn')
    results[:runtime] = {
      public_gate: ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY,
      external_runtime: ChatRing::AssistantSpike::EXTERNAL_RUNTIME_ENABLED,
      managed_self_webhooks: 0,
      webhook_deliveries: 0,
      nonterminal_turns: 0,
      rails_image_commit: File.read('/app/.git_sha').strip
    }
    results[:proof_scope] = {
      server_processes: %w[rails sidekiq postgres redis docsgpt_api docsgpt_worker],
      native_widget_http: true,
      native_action_cable_payload: true,
      connected_browser_rendering: 'separate_required_gate',
      non_widget_channel_certification: 'separate_required_gate',
      public_release_ready: false
    }
  end

  def create_visitor(email:, conversation: false)
    contact = Contact.create!(account: account, name: "Proof Visitor #{SecureRandom.hex(4)}", email: email)
    contact_inbox = ContactInbox.create!(
      contact: contact,
      inbox: inbox,
      source_id: "proof-#{run_id}-#{SecureRandom.uuid}"
    )
    token = Widget::TokenService.new(
      payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }
    ).generate_token
    result = { contact: contact, contact_inbox: contact_inbox, token: token }
    if conversation
      result[:conversation] = Conversation.create!(
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :pending,
        assignee_agent_bot: connection.agent_bot
      )
    end
    result
  end

  def create_binding_fixture!(label)
    fixture_channel = Channel::WebWidget.create!(account: account, website_url: "https://#{label}.proof.invalid")
    fixture_inbox = Inbox.create!(
      account: account,
      channel: fixture_channel,
      name: "Proof #{label} #{run_id}",
      greeting_enabled: false,
      enable_email_collect: false,
      working_hours_enabled: false
    )
    fixture_contact = Contact.create!(account: account, name: "Proof #{label} visitor")
    fixture_contact_inbox = ContactInbox.create!(
      contact: fixture_contact,
      inbox: fixture_inbox,
      source_id: "proof-#{label}-#{SecureRandom.uuid}"
    )
    fixture_assistant = workspace.assistants.create!(name: "Proof #{label} Assistant #{run_id}")
    ChatRing::AssistantVersions::Publisher.new(
      assistant: fixture_assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
      configuration: {
        identity: { 'name' => "Proof #{label} Assistant" },
        goals: ['Answer grounded pricing questions.'],
        instructions: 'Use supplied evidence only.',
        response_guidelines: ['Keep the answer concise.'],
        guardrails: ['Never invent facts.'],
        handoff_policy: { 'on_insufficient_evidence' => 'handoff', 'on_provider_failure' => 'handoff' },
        llm_provider: 'openai',
        llm_model: 'gpt-5.4'
      }
    ).call
    fixture_connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: fixture_assistant).call
    create_incoming_automation!(
      name: "Proof #{label} observation #{run_id}",
      actions: [{ 'action_name' => 'add_label', 'action_params' => ["proof-fixture-#{fixture_inbox.id}"] }],
      target_inbox: fixture_inbox
    )
    fixture_token = Widget::TokenService.new(
      payload: { source_id: fixture_contact_inbox.source_id, inbox_id: fixture_inbox.id }
    ).generate_token
    BindingFixture.new(
      assistant: fixture_assistant,
      connection: fixture_connection,
      channel: fixture_channel,
      inbox: fixture_inbox,
      contact: fixture_contact,
      contact_inbox: fixture_contact_inbox,
      token: fixture_token
    )
  end

  def fixture_label(fixture)
    "proof-fixture-#{fixture.inbox.id}"
  end

  def start_binding(fixture)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        fixture_assistant = ChatRing::Assistant.find(fixture.assistant.id)
        fixture_inbox = Inbox.find(fixture.inbox.id)
        ChatRing::AssistantProvisioning::InboxBindingActivator.new(
          assistant: fixture_assistant,
          inbox: fixture_inbox
        ).call
      end
    end
  end

  def post_first_widget(fixture, endpoint, content)
    response = if endpoint == :conversations
                 post_json(
                   '/api/v1/widget/conversations',
                   {
                     website_token: fixture.channel.website_token,
                     contact: { name: fixture.contact.name },
                     message: { content: content, timestamp: Time.current.to_i }
                   },
                   'X-Auth-Token' => fixture.token
                 )
               else
                 post_json(
                   '/api/v1/widget/messages',
                   {
                     website_token: fixture.channel.website_token,
                     message: { content: content, timestamp: Time.current.to_i }
                   },
                   'X-Auth-Token' => fixture.token
                 )
               end
    assert!(response.is_a?(Net::HTTPSuccess), "first Widget #{endpoint} POST failed with HTTP #{response.code}")
    payload = JSON.parse(response.body)
    message_id = endpoint == :conversations ? payload.fetch('messages').first.fetch('id') : payload.fetch('id')
    Message.find(message_id)
  end

  def checkout_record_lock!(table, record_id)
    raise Failure, "unsupported proof lock table #{table}" unless %w[accounts inboxes].include?(table)

    record_id = Integer(record_id)
    lock_connection = ActiveRecord::Base.connection_pool.checkout
    lock_connection.execute('BEGIN')
    pid = lock_connection.select_value('SELECT pg_backend_pid()')
    lock_connection.execute("SELECT id FROM #{table} WHERE id = #{record_id} FOR UPDATE")
    [lock_connection, pid]
  end

  def release_record_lock!(lock_connection)
    lock_connection.execute('COMMIT')
    ActiveRecord::Base.connection_pool.checkin(lock_connection)
  rescue StandardError => e
    begin
      lock_connection.execute('ROLLBACK')
    rescue StandardError
      nil
    end
    begin
      ActiveRecord::Base.connection_pool.checkin(lock_connection)
    rescue StandardError
      nil
    end
    raise e
  end

  def wait_for_blocked_backend!(blocker_pid, relation_name, exclude_pids: [])
    excluded = [Integer(blocker_pid), *exclude_pids.map { |pid| Integer(pid) }]
    wait_for("#{relation_name} lock waiter behind PID #{blocker_pid}", timeout: 30) do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT pid
        FROM pg_stat_activity
        WHERE pid NOT IN (#{excluded.join(',')})
          AND wait_event_type = 'Lock'
          AND #{Integer(blocker_pid)} = ANY(pg_blocking_pids(pid))
          AND query ILIKE '%#{relation_name}%'
        ORDER BY query_start
        LIMIT 1
      SQL
    end
  end

  def create_incoming_automation!(name:, actions:, target_inbox: inbox)
    AutomationRule.create!(
      account: account,
      name: name,
      event_name: 'message_created',
      conditions: [
        {
          'values' => [target_inbox.id],
          'attribute_key' => 'inbox_id',
          'query_operator' => 'AND',
          'filter_operator' => 'equal_to'
        },
        {
          'values' => ['incoming'],
          'attribute_key' => 'message_type',
          'query_operator' => nil,
          'filter_operator' => 'equal_to'
        }
      ],
      actions: actions,
      active: true
    )
  end

  def post_widget(visitor, content)
    response = if visitor[:conversation]
                 post_json(
                   '/api/v1/widget/messages',
                   { website_token: channel.website_token, message: { content: content, timestamp: Time.current.to_i } },
                   'X-Auth-Token' => visitor.fetch(:token)
                 )
               else
                 post_json(
                   '/api/v1/widget/conversations',
                   {
                     website_token: channel.website_token,
                     contact: { name: visitor.fetch(:contact).name },
                     message: { content: content, timestamp: Time.current.to_i }
                   },
                   'X-Auth-Token' => visitor.fetch(:token)
                 )
               end
    assert!(response.is_a?(Net::HTTPSuccess), "Widget POST failed with HTTP #{response.code}")
    payload = JSON.parse(response.body)
    message_id = visitor[:conversation] ? payload.fetch('id') : payload.fetch('messages').first.fetch('id')
    message = Message.find(message_id)
    visitor[:conversation] ||= message.conversation
    message
  end

  def assert_widget_refresh_includes_citations!(visitor, message, citations)
    response = get_json(
      '/api/v1/widget/messages',
      { website_token: channel.website_token },
      'X-Auth-Token' => visitor.fetch(:token)
    )
    assert!(response.is_a?(Net::HTTPSuccess), "Widget history GET failed with HTTP #{response.code}")
    refreshed = JSON.parse(response.body).fetch('payload').find { |item| item.fetch('id') == message.id }
    assert!(refreshed, 'supported AI Message is absent from Widget refresh history')
    assert!(refreshed.dig('content_attributes', 'chatring_citations') == citations,
            'visitor-safe citations did not survive Widget refresh')
    assert!(!refreshed.key?('additional_attributes'), 'Widget refresh exposed internal Message attributes')
  end

  def subscribe_to_action_cable!(contact_inbox, messages)
    subscribed = Queue.new
    callback = lambda do |raw_payload|
      messages << JSON.parse(raw_payload)
    rescue JSON::ParserError
      messages << { 'invalid_json' => true }
    end
    ActionCable.server.pubsub.subscribe(contact_inbox.pubsub_token, callback, -> { subscribed << true })
    wait_for('ActionCable contact subscription') do
      subscribed.pop(true)
    rescue ThreadError
      nil
    end
    callback
  end

  def unsubscribe_from_action_cable(contact_inbox, callback)
    return unless contact_inbox && callback

    ActionCable.server.pubsub.unsubscribe(contact_inbox.pubsub_token, callback)
  end

  def assert_action_cable_citations!(messages, outgoing, turn, citations)
    payload = wait_for('native ActionCable AgentBot Message payload') do
      next_payload = messages.pop(true)
      next unless next_payload['event'] == Message::MESSAGE_CREATED
      next unless next_payload.dig('data', 'id') == outgoing.id

      next_payload
    rescue ThreadError
      nil
    end
    data = payload.fetch('data')
    assert!(data.dig('content_attributes', 'chatring_citations') == citations,
            'ActionCable citations differ from the persisted native Message')
    serialized = JSON.generate(data)
    forbidden = [*turn.evidence.pluck(:evidence_id), *turn.evidence.pluck(:excerpt)].compact.map(&:to_s)
    assert!(forbidden.none? { |value| value.present? && serialized.include?(value) },
            'ActionCable payload exposed internal turn/evidence data')
    internal_attributes = data.fetch('additional_attributes', {})
    assert!(!internal_attributes.key?('chatring_ai_turn_id') && !internal_attributes.key?('chatring_evidence_ids'),
            'ActionCable payload exposed internal ChatRing Message attributes')
  end

  def post_dashboard_reply(conversation, content)
    response = post_json(
      "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
      { content: content, private: false },
      human.create_new_auth_token
    )
    assert!(response.is_a?(Net::HTTPSuccess), "dashboard reply failed with HTTP #{response.code}")
    Message.find(JSON.parse(response.body).fetch('id'))
  end

  def wait_for_provider_barrier!
    wait_for('provider barrier', timeout: 90) { File.exist?(File.join(state_dir, 'provider_entered')) }
  end

  def install_ai_insert_barrier!
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      CREATE OR REPLACE FUNCTION chatring_proof_block_ai_insert()
      RETURNS trigger AS $$
      BEGIN
        IF NEW.source_id LIKE 'chatring:reply:%' THEN
          PERFORM pg_advisory_lock(#{AI_INSERT_ADVISORY_LOCK});
          PERFORM pg_advisory_unlock(#{AI_INSERT_ADVISORY_LOCK});
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      DROP TRIGGER IF EXISTS chatring_proof_ai_insert ON messages;
      CREATE TRIGGER chatring_proof_ai_insert
      BEFORE INSERT ON messages
      FOR EACH ROW EXECUTE FUNCTION chatring_proof_block_ai_insert();
    SQL
  end

  def checkout_ai_insert_lock!
    connection = ActiveRecord::Base.connection_pool.checkout
    connection.execute("SELECT pg_advisory_lock(#{AI_INSERT_ADVISORY_LOCK})")
    connection
  end

  def wait_for_ai_insert_lock!
    wait_for('guarded AI Message insert to reach PostgreSQL barrier', timeout: 90) do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT activity.pid
        FROM pg_locks waiting
        JOIN pg_stat_activity activity ON activity.pid = waiting.pid
        WHERE waiting.locktype = 'advisory'
          AND waiting.granted = FALSE
          AND waiting.classid = 0
          AND waiting.objid = #{AI_INSERT_ADVISORY_LOCK}
          AND activity.query ILIKE '%INSERT%messages%'
        LIMIT 1
      SQL
    end
  end

  def wait_for_native_writer_blocked_by!(ai_insert_pid)
    wait_for('native writer to block behind the guarded AI transaction', timeout: 30) do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT pid
        FROM pg_stat_activity
        WHERE pid <> #{Integer(ai_insert_pid)}
          AND wait_event_type = 'Lock'
          AND #{Integer(ai_insert_pid)} = ANY(pg_blocking_pids(pid))
          AND (query ILIKE '%inboxes%' OR query ILIKE '%conversations%')
        ORDER BY query_start
        LIMIT 1
      SQL
    end
  end

  def release_ai_insert_lock!(connection)
    connection.execute("SELECT pg_advisory_unlock(#{AI_INSERT_ADVISORY_LOCK})")
    ActiveRecord::Base.connection_pool.checkin(connection)
  end

  def remove_ai_insert_barrier!
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      DROP TRIGGER IF EXISTS chatring_proof_ai_insert ON messages;
      DROP FUNCTION IF EXISTS chatring_proof_block_ai_insert();
    SQL
  rescue StandardError => e
    warn "proof AI insert barrier cleanup failed: #{e.class}"
  end

  def retire_and_schedule_pinned_index!
    knowledge_base.with_lock do
      knowledge_base.reload
      knowledge_base.update!(active_knowledge_index: nil)
      knowledge_index.reload.update!(status: 'retired')
      ChatRing::Knowledge::ProviderCleanupScheduler.schedule!(
        knowledge_index,
        eligible_at: Time.current,
        force: true,
        enqueue: true
      )
    end
  end

  def post_json(path, payload, headers = {})
    uri = app_url.dup
    uri.path = path
    request = Net::HTTP::Post.new(uri)
    request['content-type'] = 'application/json'
    headers.each { |name, value| request[name] = value }
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
  end

  def get_json(path, query, headers = {})
    uri = app_url.dup
    uri.path = path
    uri.query = URI.encode_www_form(query)
    request = Net::HTTP::Get.new(uri)
    headers.each { |name, value| request[name] = value }
    Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
  end

  def wait_for_turn(message)
    wait_for("AITurn for Message #{message.id}") { ChatRing::AiTurn.find_by(trigger_message: message) }
  end

  def wait_for_terminal_turn(message)
    turn = wait_for_turn(message)
    wait_for("terminal AITurn #{turn.id}") do
      turn.reload
      turn if turn.completed_at.present? && ChatRing::AiTurn::NONTERMINAL_STATUSES.exclude?(turn.status)
    end
  end

  def wait_for_bot_message(turn)
    wait_for("AgentBot Message for AITurn #{turn.id}") do
      turn.outbound_commit&.reload&.message
    end
  end

  def wait_for(label, timeout: WAIT_TIMEOUT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      raise Failure, "timed out waiting for #{label}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep POLL_INTERVAL
    end
  end

  def reset_provider_barrier!
    FileUtils.rm_f(Dir[File.join(state_dir, 'provider_*')])
    FileUtils.rm_f(File.join(state_dir, 'release_provider'))
  end

  def assert!(condition, message)
    raise Failure, message unless condition
  end

  def write_result!
    path = File.join(state_dir, 'result.json')
    File.write(path, JSON.pretty_generate(results))
    File.chmod(0o600, path)
  end

  def cleanup_provider!
    return if knowledge_index.blank? || !ChatRing::KnowledgeIndex.exists?(knowledge_index.id)

    cleanup = knowledge_base.with_lock do
      knowledge_base.reload
      knowledge_base.update!(active_knowledge_index: nil) if knowledge_base.active_knowledge_index_id == knowledge_index.id
      knowledge_index.reload
      knowledge_index.update!(status: 'retired') if knowledge_index.status == 'active'
      ChatRing::Knowledge::ProviderCleanupScheduler.schedule!(
        knowledge_index,
        eligible_at: Time.current,
        force: true,
        enqueue: false
      )
    end
    ChatRing::Knowledge::ProviderCleanupJob.perform_now(cleanup.id) if cleanup
  rescue StandardError => e
    warn "proof provider cleanup failed: #{e.class}"
  end
end

ChatRingWebWidgetProof.new.call
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
