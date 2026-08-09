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

  it 'fails closed when Dialogflow is configured' do
    publish
    provision
    create(:integrations_hook, :dialogflow, account: account, inbox: inbox)

    expect do
      described_class.new(assistant: assistant, inbox: inbox).call
    end.to raise_error(ChatRing::AssistantProvisioning::AgentBotConnector::ConflictError)
  end

  it 'rejects binding when a potentially matching automation can send a public reply' do
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

  it 'switches Assistants by draining the old binding under the Inbox lock' do
    publish
    provision
    first = described_class.new(assistant: assistant, inbox: inbox).call
    replacement = ChatRing::Assistant.create!(workspace: workspace, name: 'Sales')
    publish(replacement)
    provision(replacement)

    second = described_class.new(assistant: replacement, inbox: inbox).call

    expect(first.reload).to be_draining
    expect(second).to be_active
    expect(second.binding_version).to eq(2)
    expect(inbox.reload.agent_bot).to eq(replacement.agent_bot_connection.agent_bot)
  end
end
