require 'rails_helper'

RSpec.describe ChatRing::Playbooks::InitialQuestionPreparer do
  let(:context) { build_context }
  let(:turn) { context.fetch(:turn) }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  it 'prepares the published question without retrieval, inference, or a direct Message write' do
    turn

    expect do
      prepared = described_class.call(turn, context_digest: Digest::SHA256.hexdigest('playbook-context'))
      expect(prepared).to eq(described_class::PREPARED)
    end.not_to change(Message, :count)

    expect(turn.reload).to have_attributes(status: 'ready_to_commit', decision_type: 'clarification')
    expect(turn.decision_payload).to include(
      'response_text' => 'What service do you need?',
      'playbook_control' => include(
        'action' => 'ask_current_step'
      )
    )
    expect(turn.outbound_commit).to have_attributes(status: 'pending', outcome_type: 'reply')
    expect(turn.inbox_playbook_execution.reload).to be_status_active
  end

  it 'does not prepare another initial question after the execution has entered its waiting state' do
    execution = turn.inbox_playbook_execution
    execution.update!(status: :waiting_for_customer)
    turn.class.where(id: turn.id).update_all( # rubocop:disable Rails/SkipsModelValidations -- stale turn characterization
      playbook_execution_lock_version: execution.lock_version
    ) # rubocop:enable Rails/SkipsModelValidations

    expect(described_class.call(turn.reload, context_digest: Digest::SHA256.hexdigest('playbook-context')))
      .to eq(described_class::NOT_APPLICABLE)
    expect(turn.outbound_commit).to be_nil
  end

  it 'terminalizes lost native eligibility without continuing into retrieval' do
    turn.conversation.update!(status: :open, assignee_agent_bot: nil)

    expect(described_class.call(turn, context_digest: Digest::SHA256.hexdigest('playbook-context')))
      .to eq(described_class::TERMINALIZED)
    expect(turn.reload).to have_attributes(status: 'ineligible', decision_type: 'conversation_not_pending')
    expect(turn.outbound_commit).to be_nil
    expect(turn.inbox_playbook_execution.reload).to be_status_superseded
  end

  private

  def build_context
    ChatRingPlaybookSpecSupport.build
  end
end
