require 'rails_helper'

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
    it 'commits exactly one ordinary message across job retries' do
      2.times { described_class.perform_now(turn.id) }

      expect(turn.reload).to be_status_committed
      expect(turn.outbound_commit).to be_status_committed
      expect(conversation.messages.outgoing.where(sender: connection.agent_bot).pluck(:content)).to eq(['Widgets are supported.'])
    end

    it 'performs an expected-owner handoff without creating a public message' do
      turn.update!(decision_type: 'handoff', decision_payload: {
                     'decision_type' => 'handoff', 'response_text' => '',
                     'reason_code' => 'human_requested', 'evidence_ids' => []
                   })

      expect { described_class.perform_now(turn.id) }.not_to change(Message, :count)
      expect(turn.reload).to be_status_handed_off
      expect(conversation.reload).to be_open
      expect(conversation.assignee_agent_bot).to be_nil
    end

    it 'does not commit after human takeover wins first' do
      turn
      conversation.bot_handoff!

      expect { described_class.perform_now(turn.id) }.not_to(change { conversation.messages.outgoing.count })
      expect(turn.reload).to be_status_cancelled
      expect(turn.failure_code).to eq('conversation_not_pending')
    end
  end
end
