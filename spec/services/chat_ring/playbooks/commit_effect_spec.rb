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
        'step_id' => 'ask_need',
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

  private

  def build_prepared_turn
    base = ChatRing::Playbooks::InitialQuestionPreparerSpecSupport.build
    ChatRing::Playbooks::InitialQuestionPreparer.call(
      base.fetch(:turn),
      context_digest: Digest::SHA256.hexdigest('playbook-context')
    )
    base
  end
end
