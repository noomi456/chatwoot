require 'rails_helper'

RSpec.describe ChatRing::AssistantProvisioning::InboxBindingActivator do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:knowledge_scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:inbox) { create(:inbox, account: account) }

  def publish(target = assistant, instructions: 'Answer from evidence.')
    ChatRing::AssistantVersions::Publisher.new(
      assistant: target,
      knowledge_scope: knowledge_scope,
      configuration: { instructions: instructions, identity: { name: target.name } }
    ).call
  end

  def provision(target = assistant)
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: target).call
  end

  it 'publishes monotonically numbered immutable versions' do
    first = publish
    second = publish(assistant, instructions: 'Use concise evidence.')

    expect([first.version, second.version]).to eq([1, 2])
    expect(assistant.reload.current_version).to eq(second)
    expect(first.update(instructions: 'Mutated')).to be(false)
  end

  it 'provisions one account-owned managed AgentBot without a public self-webhook or copied raw secrets' do
    publish

    connection = provision

    expect(connection).to be_active
    expect(connection.agent_bot).to be_chatring_assistant
    expect(connection.agent_bot.account).to eq(account)
    expect(connection.agent_bot.outgoing_url).to be_nil
    expect(connection.access_token_secret_ref).not_to include(connection.agent_bot.access_token.token)
    expect(connection.webhook_secret_ref).not_to include(connection.agent_bot.secret)
    expect(provision).to eq(connection)
  end

  it 'removes a legacy public self-webhook when verifying an existing connection' do
    publish
    connection = provision
    connection.agent_bot.update!(outgoing_url: connection.webhook_url)

    expect(provision.agent_bot.reload.outgoing_url).to be_nil
  end

  it 'activates an idempotent versioned Inbox binding' do
    publish
    provision
    activator = described_class.new(assistant: assistant, inbox: inbox)

    first = activator.call
    second = activator.call

    expect(first).to eq(second)
    expect(first).to be_active
    expect(first.binding_version).to eq(1)
    expect(assistant.reload).to be_active
    expect(inbox.reload.agent_bot).to eq(assistant.agent_bot_connection.agent_bot)
  end

  it 'uses the same managed AgentBot when one Assistant serves multiple Inboxes' do
    publish
    provision
    other_inbox = create(:inbox, account: account)

    first = described_class.new(assistant: assistant, inbox: inbox).call
    second = described_class.new(assistant: assistant, inbox: other_inbox).call

    expect(first.assistant_agent_bot_connection).to eq(second.assistant_agent_bot_connection)
    expect(inbox.reload.agent_bot).to eq(other_inbox.reload.agent_bot)
  end

  it 'rejects non-Widget Inboxes before creating a binding' do
    publish
    provision
    email_inbox = create(:inbox, :with_email, account: account)

    expect do
      described_class.new(assistant: assistant, inbox: email_inbox).call
    end.to raise_error(ActiveRecord::RecordInvalid, /Web Widget Inboxes only/)

    expect(email_inbox.reload.agent_bot).to be_nil
    expect(assistant.inbox_bindings).to be_empty
  end

  it 'rejects activation when archive wins the Account lock' do
    publish
    provision
    archive_started = Queue.new
    allow_archive_to_commit = Queue.new

    archiver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        account.reload.with_lock do
          assistant.reload.update!(status: :archived)
          archive_started << true
          allow_archive_to_commit.pop
        end
      end
    end
    archive_started.pop
    activator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(assistant: assistant.reload, inbox: inbox.reload).call
      end
    rescue StandardError => e
      e
    end
    allow_archive_to_commit << true

    archiver.join
    expect(activator.value).to be_a(ActiveRecord::RecordInvalid)
    expect(inbox.reload.agent_bot).to be_nil
    expect(assistant.inbox_bindings).to be_empty
  end

  it 'fails closed when Dialogflow is configured' do
    publish
    provision
    create(:integrations_hook, :dialogflow, account: account, inbox: inbox)

    expect do
      described_class.new(assistant: assistant, inbox: inbox).call
    end.to raise_error(ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError)
  end

  it 'allows binding when message-created Automation effects use the native completion barrier' do
    publish
    provision
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [
        {
          'attribute_key' => 'inbox_id',
          'filter_operator' => 'equal_to',
          'values' => [inbox.id],
          'query_operator' => 'AND'
        },
        {
          'attribute_key' => 'message_type',
          'filter_operator' => 'equal_to',
          'values' => ['incoming'],
          'query_operator' => nil
        }
      ],
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Automation reply'] }]
    )

    expect(described_class.new(assistant: assistant, inbox: inbox).call).to be_active
  end

  it 'rejects binding when message-created responder rules can match outgoing messages' do
    publish
    provision
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [{
        'attribute_key' => 'inbox_id',
        'filter_operator' => 'equal_to',
        'values' => [inbox.id],
        'query_operator' => nil
      }],
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Automation reply'] }]
    )

    expect do
      described_class.new(assistant: assistant, inbox: inbox).call
    end.to raise_error(ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError)
  end

  it 'rejects binding when an unobserved Automation event can send a public reply' do
    publish
    provision
    create(
      :automation_rule,
      account: account,
      event_name: 'conversation_updated',
      conditions: [{
        'attribute_key' => 'inbox_id',
        'filter_operator' => 'equal_to',
        'values' => [inbox.id],
        'query_operator' => nil
      }],
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Automation reply'] }]
    )

    expect do
      described_class.new(assistant: assistant, inbox: inbox).call
    end.to raise_error(ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError)
  end

  it 'rejects binding when message-created Automation invokes an indirect webhook' do
    publish
    provision
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [{
        'attribute_key' => 'inbox_id',
        'filter_operator' => 'equal_to',
        'values' => [inbox.id],
        'query_operator' => nil
      }],
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook'] }]
    )

    expect do
      described_class.new(assistant: assistant, inbox: inbox).call
    end.to raise_error(ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError)
  end

  it 'allows binding when a matching automation only adds a label' do
    publish
    provision
    create(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [{
        'attribute_key' => 'inbox_id',
        'filter_operator' => 'equal_to',
        'values' => [inbox.id],
        'query_operator' => nil
      }],
      actions: [{ 'action_name' => 'add_label', 'action_params' => ['priority'] }]
    )

    expect(described_class.new(assistant: assistant, inbox: inbox).call).to be_active
  end

  it 'hands off old-bot Conversations and cancels unfinished turns before switching Assistants' do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
    publish
    connection = provision
    first = described_class.new(assistant: assistant, inbox: inbox).call
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :pending,
      assignee_agent_bot: connection.agent_bot
    )
    trigger_message = ChatRing::ConversationWriteBoundary.new(conversation: conversation).call do
      create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: conversation.contact,
        message_type: :incoming
      )
    end
    EventDispatcherJob.perform_now(
      Message::MESSAGE_CREATED,
      trigger_message.created_at,
      { message: trigger_message, performed_by: nil }
    )
    turn = ChatRing::AiTurn.find_by!(trigger_message: trigger_message)
    replacement = ChatRing::Assistant.create!(workspace: workspace, name: 'Sales')
    publish(replacement)
    provision(replacement)

    second = described_class.new(assistant: replacement, inbox: inbox).call

    expect(first.reload).to be_draining
    expect(second).to have_attributes(status: 'active', binding_version: 2)
    expect(inbox.reload.agent_bot).to eq(replacement.agent_bot_connection.agent_bot)
    expect(conversation.reload).to be_open
    expect(conversation.assignee_agent_bot).to be_nil
    expect(turn.reload).to be_status_cancelled
    expect(turn.failure_code).to eq('binding_rebound')
  end

  it 'rolls back a replacement when native handoff fails' do
    publish
    connection = provision
    first = described_class.new(assistant: assistant, inbox: inbox).call
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :pending,
      assignee_agent_bot: connection.agent_bot
    )
    replacement = ChatRing::Assistant.create!(workspace: workspace, name: 'Sales')
    publish(replacement)
    provision(replacement)
    drainer = instance_double(ChatRing::AssistantProvisioning::InboxBindingDrainer)
    allow(ChatRing::AssistantProvisioning::InboxBindingDrainer).to receive(:new).and_return(drainer)
    allow(drainer).to receive(:call_with_lock!).and_raise(ActiveRecord::RecordNotSaved)

    expect do
      described_class.new(assistant: replacement, inbox: inbox).call
    end.to raise_error(ActiveRecord::RecordNotSaved)

    expect(first.reload).to be_active
    expect(inbox.reload.agent_bot).to eq(connection.agent_bot)
    expect(conversation.reload.assignee_agent_bot).to eq(connection.agent_bot)
    expect(replacement.inbox_bindings).to be_empty
  end

  it 'disables a binding only after native handoff completes' do
    publish
    connection = provision
    binding = described_class.new(assistant: assistant, inbox: inbox).call
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :pending,
      assignee_agent_bot: connection.agent_bot
    )

    result = ChatRing::AssistantProvisioning::InboxBindingDeactivator.new(binding: binding).call

    expect(result).to be_inactive
    expect(inbox.reload.agent_bot).to be_nil
    expect(conversation.reload).to be_open
    expect(conversation.assignee_agent_bot).to be_nil
  end

  it 'archives an Assistant only after all of its Inbox Conversations are handed off' do
    publish
    connection = provision
    other_inbox = create(:inbox, account: account)
    bindings = [inbox, other_inbox].map { |target| described_class.new(assistant: assistant, inbox: target).call }
    conversations = [inbox, other_inbox].map do |target|
      create(:conversation, account: account, inbox: target, status: :pending, assignee_agent_bot: connection.agent_bot)
    end

    ChatRing::AssistantProvisioning::AssistantArchiver.new(assistant: assistant).call

    expect(assistant.reload).to be_archived
    expect(connection.reload).to be_inactive
    expect(bindings.map { |binding| binding.reload.status }).to all(eq('inactive'))
    expect([inbox, other_inbox].map { |target| target.reload.agent_bot }).to all(be_nil)
    expect(conversations.map { |conversation| conversation.reload.status }).to all(eq('open'))
    expect(conversations.map(&:assignee_agent_bot)).to all(be_nil)
  end
end
