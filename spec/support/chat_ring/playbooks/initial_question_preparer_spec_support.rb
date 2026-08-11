module ChatRing::Playbooks::InitialQuestionPreparerSpecSupport
  module_function

  def build
    account = FactoryBot.create(:account)
    workspace = account.chat_ring_workspace
    inbox = FactoryBot.create(:channel_widget, account: account).inbox
    assistant_context = create_assistant_context(workspace, inbox)
    native_context = create_native_context(account, inbox, assistant_context.fetch(:connection))
    execution = create_execution(workspace, inbox, native_context.fetch(:conversation), native_context.fetch(:trigger))
    turn = create_turn(workspace, assistant_context, native_context, execution)
    { turn: turn, connection: assistant_context.fetch(:connection) }
  end

  def create_assistant_context(workspace, inbox)
    assistant = workspace.assistants.create!(name: 'Sales')
    assistant_version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: workspace.knowledge_scopes.find_by!(business_wide: true)
    ).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    binding = ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    { assistant: assistant, assistant_version: assistant_version, connection: connection, binding: binding }
  end

  def create_native_context(account, inbox, connection)
    conversation = FactoryBot.create(:conversation, account: account, inbox: inbox, status: :pending,
                                                    assignee_agent_bot: connection.agent_bot)
    trigger = FactoryBot.create(:message, account: account, inbox: inbox, conversation: conversation,
                                          sender: conversation.contact, message_type: :incoming, private: false,
                                          content: 'Pricing options')
    { conversation: conversation, trigger: trigger }
  end

  def create_turn(workspace, assistant_context, native_context, execution)
    ChatRing::AiTurn.create!(
      workspace: workspace,
      conversation: native_context.fetch(:conversation),
      trigger_message: native_context.fetch(:trigger),
      inbox_assistant_binding: assistant_context.fetch(:binding),
      binding_version: assistant_context.fetch(:binding).binding_version,
      assistant: assistant_context.fetch(:assistant),
      assistant_version: assistant_context.fetch(:assistant_version),
      expected_agent_bot: assistant_context.fetch(:connection).agent_bot,
      inbox_playbook_execution: execution,
      playbook_execution_lock_version: execution.lock_version,
      playbook_step_id: execution.current_step_id,
      status: :running,
      native_handling_snapshot: { 'automation' => { 'completed' => true, 'effects' => [] } },
      deadline_at: 2.minutes.from_now
    )
  end

  def create_execution(workspace, inbox, conversation, trigger)
    actor = FactoryBot.create(:user, account: conversation.account, role: :administrator)
    playbook = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: 'Pricing discovery',
      purpose: 'Qualify pricing interest.',
      draft_definition: definition
    )
    version = ChatRing::Playbooks::Publisher.new(playbook: playbook, actor: actor, expected_lock_version: 0).call
    ChatRing::InboxPlaybookExecution.create!(
      workspace: workspace,
      conversation: conversation,
      inbox_playbook_version: version,
      current_step_id: 'ask_need',
      status: :active,
      last_trigger_message: trigger,
      started_at: Time.current
    )
  end

  def definition
    {
      trigger_phrases: ['pricing options'],
      entry_step_id: 'ask_need',
      collected_fields: [{ key: 'need', type: 'string', required: true, native_contact_attribute_key: nil }],
      tool_allowlist: [],
      steps: [
        { id: 'ask_need', kind: 'ask_text', prompt: 'What service do you need?', field_key: 'need', next_step_id: 'complete' },
        { id: 'complete', kind: 'terminal', outcome: 'complete', message: 'Thank you. Your request is complete.' }
      ],
      safety_rules: { on_human_request: 'native_availability', on_side_question: 'answer_then_resume' }
    }
  end
end
