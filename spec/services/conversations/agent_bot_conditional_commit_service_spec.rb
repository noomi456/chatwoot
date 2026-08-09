require 'rails_helper'

RSpec.describe Conversations::AgentBotConditionalCommitService do
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
      decision_type: 'reply',
      decision_payload: {
        'decision_type' => 'reply',
        'response_text' => 'Widgets are supported.',
        'reason_code' => 'answered',
        'evidence_ids' => ['evidence-1']
      }
    )
  end
  let(:outbound_commit) do
    ChatRing::OutboundCommit.create!(
      ai_turn: turn,
      idempotency_key: Digest::SHA256.hexdigest("chatring:reply:#{workspace.id}:#{turn.id}")
    )
  end

  def service(agent_bot: connection.agent_bot, responding_to_message_id: trigger_message.id)
    described_class.new(
      conversation: conversation,
      agent_bot: agent_bot,
      expected_agent_bot_id: connection.agent_bot.id,
      responding_to_message_id: responding_to_message_id,
      idempotency_key: outbound_commit.idempotency_key,
      message: { content: 'Widgets are supported.', content_type: 'text' }
    )
  end

  it 'creates one ordinary AgentBot message and commits the durable idempotency marker' do
    result = service.perform

    expect(result.idempotent).to be(false)
    expect(result.message).to have_attributes(sender: connection.agent_bot, content: 'Widgets are supported.', private: false)
    expect(outbound_commit.reload).to be_status_committed
    expect(outbound_commit.message).to eq(result.message)
  end

  it 'returns the original message when the same idempotency key is retried' do
    original = service.perform.message
    retry_result = nil

    expect { retry_result = service.perform }.not_to change(Message, :count)
    expect(retry_result.idempotent).to be(true)
    expect(retry_result.message).to eq(original)
  end

  it 'rejects a reply after a newer customer message' do
    outbound_commit
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: conversation.contact,
                     message_type: :incoming, private: false, content: 'One more question')

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'newer_customer_message')
    expect(outbound_commit.reload).to be_status_rejected
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  it 'rejects a reply after a public human response' do
    outbound_commit
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: create(:user, account: account),
                     message_type: :outgoing, private: false, content: 'I will take this')

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'newer_human_reply')
    expect(conversation.reload.assignee_agent_bot).to be_nil
    expect(conversation).to be_open
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  it 'does not treat a private human note as superseding' do
    outbound_commit
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: create(:user, account: account),
                     message_type: :outgoing, private: true, content: 'Internal note')

    expect(service.perform.message).to be_present
  end

  it 'rejects a system or wrong-account AgentBot principal' do
    global_bot = create(:agent_bot, account: nil, bot_type: :chatring_assistant)
    other_account_bot = create(:agent_bot, account: create(:account), bot_type: :chatring_assistant)
    wrong_bot = create(:agent_bot, account: account, bot_type: :chatring_assistant)

    expect { service(agent_bot: global_bot).perform }.to raise_error(described_class::Unauthorized)
    expect { service(agent_bot: other_account_bot).perform }.to raise_error(described_class::Unauthorized)
    expect { service(agent_bot: wrong_bot).perform }.to raise_error(described_class::Unauthorized)
  end

  it 'rejects a responding message other than the turn trigger' do
    outbound_commit
    other_message = create(:message, account: account, inbox: inbox, conversation: conversation,
                                     sender: conversation.contact, message_type: :incoming, private: false)

    expect { service(responding_to_message_id: other_message.id).perform }
      .to raise_error(described_class::PreconditionFailed, 'invalid_trigger_message')
    expect(outbound_commit.reload).to be_status_rejected
  end

  it 'rejects a trigger that is no longer an incoming customer message' do
    outbound_commit
    trigger_message.update!(message_type: :outgoing)

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'invalid_trigger_message')
  end

  it 'rejects a human-owned conversation' do
    outbound_commit
    conversation.update!(status: :pending, assignee: create(:user, account: account), assignee_agent_bot: nil)

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'unexpected_agent_bot')
  end

  %w[open resolved snoozed].each do |status|
    it "rejects a #{status} conversation" do
      outbound_commit
      conversation.update!(status: status)

      expect { service.perform }
        .to raise_error(described_class::PreconditionFailed, 'conversation_not_pending')
    end
  end

  it 'rejects an Assistant binding change committed before the conditional reply' do
    outbound_commit
    binding.update!(status: :inactive)

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'binding_inactive')
  end

  it 'rejects an Assistant version change committed before the conditional reply' do
    outbound_commit
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'assistant_version_changed')
  end

  it 'fails closed when a competing Automation bypasses configuration validation before commit' do
    outbound_commit
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'message_created',
      conditions: [{ 'attribute_key' => 'inbox_id', 'filter_operator' => 'equal_to', 'values' => [inbox.id] }],
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['Competing response'] }]
    )
    rule.save!(validate: false)

    expect { service.perform }
      .to raise_error(described_class::PreconditionFailed, 'automation_conflict')
    expect(outbound_commit.reload).to be_status_rejected
  end
end
