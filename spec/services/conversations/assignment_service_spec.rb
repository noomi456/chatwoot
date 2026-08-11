require 'rails_helper'

describe Conversations::AssignmentService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  describe '#perform' do
    context 'when assignee_id is blank' do
      before do
        conversation.update!(assignee: agent, assignee_agent_bot: agent_bot)
      end

      it 'clears both human and bot assignees' do
        described_class.new(conversation: conversation, assignee_id: nil).perform

        conversation.reload
        expect(conversation.assignee_id).to be_nil
        expect(conversation.assignee_agent_bot_id).to be_nil
      end

      it 'preserves conversation status' do
        conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)

        described_class.new(conversation: conversation, assignee_id: nil).perform

        expect(conversation.reload.status).to eq('snoozed')
      end
    end

    context 'when assigning a user' do
      before do
        conversation.update!(assignee_agent_bot: agent_bot, assignee: nil, status: :pending)
      end

      it 'sets the agent, clears agent bot and opens the conversation' do
        result = described_class.new(conversation: conversation, assignee_id: agent.id).perform

        conversation.reload
        expect(result).to eq(agent)
        expect(conversation.assignee_id).to eq(agent.id)
        expect(conversation.assignee_agent_bot_id).to be_nil
        expect(conversation.status).to eq('open')
      end

      it 'starts the waiting clock when opening a bot-owned pending conversation' do
        conversation.update!(waiting_since: nil)

        freeze_time do
          described_class.new(conversation: conversation, assignee_id: agent.id).perform

          expect(conversation.reload.waiting_since).to eq(Time.current)
        end
      end

      it 'ends the exact waiting Playbook through the native managed-bot takeover transaction' do
        workspace = account.chat_ring_workspace
        inbox = conversation.inbox
        assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Sales')
        ChatRing::AssistantVersions::Publisher.new(
          assistant: assistant,
          knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true)
        ).call
        connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
        ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
        conversation.update!(assignee_agent_bot: connection.agent_bot, assignee: nil, status: :pending)
        trigger = create(:message, account: account, inbox: inbox, conversation: conversation,
                                   sender: conversation.contact, message_type: :incoming)
        execution = ChatRing::Playbooks::InitialQuestionPreparerSpecSupport.create_execution(
          workspace,
          inbox,
          conversation,
          trigger
        )
        execution.update!(status: :waiting_for_customer)

        described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(conversation.reload).to have_attributes(status: 'open', assignee_id: agent.id, assignee_agent_bot_id: nil)
        expect(execution.reload).to be_status_handed_off
        expect(execution.transition_history.last).to include(
          'action' => 'native_human_takeover',
          'failure_code' => 'human_assigned'
        )
      end

      it 'preserves status for ordinary human assignment changes' do
        conversation.update!(assignee_agent_bot: nil, status: :resolved)

        described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(conversation.reload.status).to eq('resolved')
      end

      it 'preserves status when taking over a bot-owned non-pending conversation' do
        conversation.update!(assignee_agent_bot: agent_bot, status: :resolved)

        described_class.new(conversation: conversation, assignee_id: agent.id).perform

        expect(conversation.reload.status).to eq('resolved')
      end
    end

    context 'when assigning an agent bot' do
      let(:service) do
        described_class.new(
          conversation: conversation,
          assignee_id: agent_bot.id,
          assignee_type: 'AgentBot'
        )
      end

      it 'sets the agent bot, clears human assignee and marks the conversation pending' do
        conversation.update!(assignee: agent, assignee_agent_bot: nil, status: :open)

        result = service.perform

        conversation.reload
        expect(result).to eq(agent_bot)
        expect(conversation.assignee_agent_bot_id).to eq(agent_bot.id)
        expect(conversation.assignee_id).to be_nil
        expect(conversation.status).to eq('pending')
      end

      it 'marks a resolved conversation pending' do
        conversation.update!(status: :resolved)

        service.perform

        expect(conversation.reload.status).to eq('pending')
      end

      it 'marks a snoozed conversation pending and clears the snooze timestamp' do
        conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)

        service.perform

        conversation.reload
        expect(conversation.status).to eq('pending')
        expect(conversation.snoozed_until).to be_nil
      end

      it 'rejects a managed Assistant bot that is not the active Inbox connection' do
        managed_bot = create(:agent_bot, account: account, bot_type: :chatring_assistant)

        expect do
          described_class.new(
            conversation: conversation,
            assignee_id: managed_bot.id,
            assignee_type: 'AgentBot'
          ).perform
        end.to raise_error(ActiveRecord::RecordInvalid, /active managed Assistant/)

        expect(conversation.reload.assignee_agent_bot).not_to eq(managed_bot)
      end

      it 'assigns the exact managed Assistant bot connected through the active Inbox binding' do
        workspace = account.chat_ring_workspace
        assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Support')
        ChatRing::AssistantVersions::Publisher.new(
          assistant: assistant,
          knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true),
          configuration: { instructions: 'Answer from evidence.' }
        ).call
        connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
        ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: conversation.inbox).call

        result = described_class.new(
          conversation: conversation,
          assignee_id: connection.agent_bot_id,
          assignee_type: 'AgentBot'
        ).perform

        expect(result).to eq(connection.agent_bot)
        expect(conversation.reload.assignee_agent_bot).to eq(connection.agent_bot)
        expect(conversation).to be_pending
      end
    end
  end
end
