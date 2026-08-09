require 'rails_helper'
require 'timeout'

RSpec.describe Conversations::AgentBotConditionalCommitService, '#perform', :aggregate_failures do
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

  after do
    ChatRing::AiTurn.where(workspace_id: workspace.id).delete_all
    Message.where(account_id: account.id).delete_all
    Conversation.where(account_id: account.id).delete_all
    workspace.reload.destroy!
    account.reload.destroy!
  end

  it 'does not let a newer customer message interleave after AI freshness validation' do
    ai_inside_boundary = Queue.new
    release_ai = Queue.new
    customer_attempting_lock = Queue.new
    service = conditional_service
    customer_message = conversation.messages.build(
      account: account,
      inbox: inbox,
      sender: conversation.contact,
      message_type: :incoming,
      private: false,
      content: 'One more question'
    )
    allow(service).to receive(:create_message).and_wrap_original do |original, *arguments|
      ai_inside_boundary << true
      release_ai.pop
      original.call(*arguments)
    end
    allow(customer_message).to receive(:lock_conversation_for_public_message).and_wrap_original do |original|
      customer_attempting_lock << true
      original.call
    end

    ai_thread = run_in_thread { service.perform }
    wait_for(ai_inside_boundary)
    customer_thread = run_in_thread { customer_message.save! }
    wait_for(customer_attempting_lock)

    customer_interleaved = conversation.messages.exists?(content: 'One more question')
    release_ai << true
    ai_result = ai_thread.value
    customer_thread.value

    expect(customer_interleaved).to be(false)
    expect(ai_result.message.id).to be < customer_message.reload.id
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot).count).to eq(1)
  end

  it 'rejects the old AI reply when a newer customer message wins the serialization order' do
    outbound_commit
    customer_inside_boundary = Queue.new
    release_customer = Queue.new
    customer_message = conversation.messages.build(
      account: account,
      inbox: inbox,
      sender: conversation.contact,
      message_type: :incoming,
      private: false,
      content: 'One more question'
    )
    allow(customer_message).to receive(:lock_conversation_for_public_message).and_wrap_original do |original|
      original.call
      customer_inside_boundary << true
      release_customer.pop
    end

    customer_thread = run_in_thread { customer_message.save! }
    wait_for(customer_inside_boundary)
    ai_thread = run_in_thread do
      conditional_service.perform
    rescue StandardError => e
      e
    end
    release_customer << true
    customer_thread.value
    error = ai_thread.value

    expect(error.class.name).to eq('Conversations::AgentBotConditionalCommitService::PreconditionFailed')
    expect(error.message).to eq('newer_customer_message')
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  it 'rejects the old AI reply when a public human reply wins the serialization order' do
    outbound_commit
    human_inside_boundary = Queue.new
    release_human = Queue.new
    human_message = conversation.messages.build(
      account: account,
      inbox: inbox,
      sender: create(:user, account: account),
      message_type: :outgoing,
      private: false,
      content: 'I will take this'
    )
    allow(human_message).to receive(:lock_conversation_for_public_message).and_wrap_original do |original|
      original.call
      human_inside_boundary << true
      release_human.pop
    end

    human_thread = run_in_thread { human_message.save! }
    wait_for(human_inside_boundary)
    ai_thread = run_in_thread do
      conditional_service.perform
    rescue StandardError => e
      e
    end
    release_human << true
    human_thread.value
    error = ai_thread.value

    expect(error.class.name).to eq('Conversations::AgentBotConditionalCommitService::PreconditionFailed')
    expect(error.message).to eq('newer_human_reply')
    expect(conversation.reload.assignee_agent_bot).to be_nil
    expect(conversation).to be_open
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  it 'creates exactly one message for concurrent identical commit requests' do
    ids = {
      conversation: conversation.id,
      agent_bot: connection.agent_bot.id,
      trigger_message: trigger_message.id,
      idempotency_key: outbound_commit.idempotency_key
    }
    start = Concurrent::CyclicBarrier.new(2)
    results = Concurrent::Array.new
    threads = Array.new(2) do
      run_in_thread do
        start.wait
        results << described_class.new(
          conversation: Conversation.find(ids[:conversation]),
          agent_bot: AgentBot.find(ids[:agent_bot]),
          expected_agent_bot_id: ids[:agent_bot],
          responding_to_message_id: ids[:trigger_message],
          idempotency_key: ids[:idempotency_key],
          message: { content: 'Widgets are supported.', content_type: 'text' }
        ).perform
      end
    end

    threads.each(&:value)

    expect(results.map(&:idempotent)).to contain_exactly(false, true)
    expect(results.map { |result| result.message.id }.uniq.one?).to be(true)
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot).count).to eq(1)
  end

  it 'rejects the old AI reply when human takeover wins the serialization order' do
    outbound_commit
    takeover_inside_boundary = Queue.new
    release_takeover = Queue.new
    takeover_conversation = Conversation.find(conversation.id)
    assignment = Conversations::AssignmentService.new(
      conversation: takeover_conversation,
      assignee_id: create(:user, account: account).id
    )
    allow(takeover_conversation).to receive(:with_lock).and_wrap_original do |original, *arguments, &block|
      original.call(*arguments) do
        takeover_inside_boundary << true
        release_takeover.pop
        block.call
      end
    end

    takeover_thread = run_in_thread { assignment.perform }
    wait_for(takeover_inside_boundary)
    ai_thread = run_in_thread do
      conditional_service.perform
    rescue StandardError => e
      e
    end
    release_takeover << true
    takeover_thread.value
    error = ai_thread.value

    expect(error.class.name).to eq('Conversations::AgentBotConditionalCommitService::PreconditionFailed')
    expect(error.message).to eq('conversation_not_pending')
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  it 'rejects the old AI reply when an Inbox Assistant rebind wins the serialization order' do
    outbound_commit
    replacement = ChatRing::Assistant.create!(workspace: workspace, name: 'Replacement')
    ChatRing::AssistantVersions::Publisher.new(assistant: replacement, knowledge_scope: scope).call
    ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: replacement).call
    rebind_inside_boundary = Queue.new
    release_rebind = Queue.new
    activator = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: replacement, inbox: inbox)
    allow(inbox).to receive(:with_lock).and_wrap_original do |original, *arguments, &block|
      original.call(*arguments) do
        rebind_inside_boundary << true
        release_rebind.pop
        block.call
      end
    end

    rebind_thread = run_in_thread { activator.call }
    wait_for(rebind_inside_boundary)
    ai_thread = run_in_thread do
      conditional_service.perform
    rescue StandardError => e
      e
    end
    release_rebind << true
    rebind_thread.value
    error = ai_thread.value

    expect(error.class.name).to eq('Conversations::AgentBotConditionalCommitService::PreconditionFailed')
    expect(error.message).to eq('binding_inactive')
    expect(conversation.messages.outgoing.where(sender: connection.agent_bot)).to be_empty
  end

  def conditional_service
    described_class.new(
      conversation: conversation,
      agent_bot: connection.agent_bot,
      expected_agent_bot_id: connection.agent_bot.id,
      responding_to_message_id: trigger_message.id,
      idempotency_key: outbound_commit.idempotency_key,
      message: { content: 'Widgets are supported.', content_type: 'text' }
    )
  end

  def run_in_thread(&)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&)
    end
  end

  def wait_for(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def run_in_transaction?
    false
  end
end
