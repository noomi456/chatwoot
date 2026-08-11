require 'rails_helper'

RSpec.describe ChatRing::Brain::InboundInvocationBuilder do
  let(:turn) { build_turn }

  before do
    stub_const('ChatRing::AssistantSpike::PUBLIC_AI_RELEASE_READY', true)
  end

  it 'builds an immutable model projection without Contact PII or private notes' do
    invocation = described_class.new(turn).build
    model_json = invocation.model_context.to_json

    expect(invocation.trusted_context).to include(
      'account_id' => turn.conversation.account_id,
      'contact_id' => turn.conversation.contact_id,
      'inbox_within_working_hours' => true
    )
    expect(invocation.model_context).not_to have_key('contact')
    expect(model_json).not_to include('Noomi Private', 'noomi@example.com', '+15551234567', 'private-contact-id', 'Private note')
    expect(invocation.audit_metadata.fetch('contact_fields_included')).to eq([])
    expect { invocation.model_context.fetch('assistant')['identity'] = {} }.to raise_error(FrozenError)
  end

  it 'preserves native speaker provenance while mapping messages to model roles', :aggregate_failures do
    invocation = described_class.new(turn).build
    history = invocation.model_context.dig('conversation', 'history').index_by { |item| item.fetch('content') }

    expect(history.fetch('Earlier customer')).to include('role' => 'user', 'speaker' => 'customer')
    expect(history.fetch('Human answer')).to include('role' => 'assistant', 'speaker' => 'human_agent')
    expect(history.fetch('Native greeting')).to include('role' => 'assistant', 'speaker' => 'native_template')
    expect(history.fetch('Automation answer')).to include('role' => 'assistant', 'speaker' => 'automation')
    expect(history.fetch('Managed AI answer')).to include('role' => 'assistant', 'speaker' => 'managed_ai')
    expect(history.fetch('External bot answer')).to include('role' => 'assistant', 'speaker' => 'external_bot_or_system')
    expect(invocation.model_context.fetch('trigger_message')).to include(
      'role' => 'user', 'speaker' => 'customer', 'content' => 'Current question'
    )
    expect(invocation.audit_metadata.fetch('speaker_provenance').pluck('speaker')).to include(
      'customer', 'human_agent', 'native_template', 'automation', 'managed_ai', 'external_bot_or_system'
    )
  end

  it 'includes only snapshot-authorized native templates created for the current trigger' do
    current_template = create(
      :message,
      account: turn.conversation.account,
      inbox: turn.conversation.inbox,
      conversation: turn.conversation,
      message_type: :template,
      content: 'Greeting sent for this question'
    )
    turn.class.where(id: turn.id).update_all( # rubocop:disable Rails/SkipsModelValidations -- immutable snapshot characterization
      native_handling_snapshot: turn.native_handling_snapshot.merge(
        'template_delta_ids' => [current_template.id],
        'greeting_message_ids' => [current_template.id]
      )
    ) # rubocop:enable Rails/SkipsModelValidations

    invocation = described_class.new(turn.reload).build

    expect(invocation.model_context.fetch('current_turn_native_messages')).to contain_exactly(
      include('speaker' => 'native_template', 'content' => 'Greeting sent for this question')
    )
    expect(invocation.audit_metadata.fetch('speaker_provenance')).to include(
      include('message_id' => current_template.id, 'speaker' => 'native_template', 'template_kind' => 'greeting')
    )
  end

  it 'keeps the model-visible trigger bounded while limiting the retrieval query to the DocsGPT contract' do
    turn.trigger_message.update!(content: 'x' * 5000)

    invocation = described_class.new(turn.reload).build

    expect(invocation.model_context.dig('trigger_message', 'content').length).to eq(4000)
    expect(invocation.query.length).to eq(ChatRing::Knowledge::DocsGptProvider::MAX_QUERY_LENGTH)
  end

  it 'projects a pinned Inbox Playbook step without exposing native target identifiers or collected values' do
    context = build_context
    publish_playbook(context)
    create_history(context)
    turn = trigger_turn(context)

    invocation = described_class.new(turn).build

    expect(invocation.trusted_context).to include(
      'inbox_playbook_execution_id' => turn.inbox_playbook_execution_id,
      'playbook_step_id' => 'ask_need'
    )
    expect(invocation.model_context.fetch('active_playbook')).to include(
      'goal' => 'Qualify pricing interest.',
      'current_step' => include('kind' => 'ask_text', 'prompt' => 'What service do you need?'),
      'pending_question' => 'What service do you need?',
      'collected_field_keys' => []
    )
    expect(invocation.model_context.fetch('active_playbook').to_json).not_to include(
      'target_playbook_version_id', 'native_contact_attribute_key'
    )
  end

  it 'lets native Conversation deletion remove its pinned Playbook execution and AI turn in either cascade order' do
    context = build_context
    publish_playbook(context)
    create_history(context)
    turn = trigger_turn(context)
    execution_id = turn.inbox_playbook_execution_id

    expect { context.fetch(:conversation).destroy! }.not_to raise_error

    expect(ChatRing::AiTurn.where(id: turn.id)).not_to exist
    expect(ChatRing::InboxPlaybookExecution.where(id: execution_id)).not_to exist
  end

  it 'removes Playbook runtime records before immutable Playbook configuration during Workspace deletion' do
    context = build_context
    publish_playbook(context)
    create_history(context)
    turn = trigger_turn(context)
    execution_id = turn.inbox_playbook_execution_id

    expect { context.fetch(:workspace).destroy! }.not_to raise_error

    expect(ChatRing::AiTurn.where(id: turn.id)).not_to exist
    expect(ChatRing::InboxPlaybookExecution.where(id: execution_id)).not_to exist
  end

  def build_turn
    context = build_context
    create_history(context)
    trigger_turn(context)
  end

  def build_context
    account = create(:account)
    workspace = account.chat_ring_workspace
    inbox = create(:channel_widget, account: account).inbox
    assistant = ChatRing::Assistant.create!(workspace: workspace, name: 'Sales')
    scope = workspace.knowledge_scopes.find_by!(business_wide: true)
    ChatRing::AssistantVersions::Publisher.new(assistant: assistant, knowledge_scope: scope).call
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    ChatRing::AssistantProvisioning::InboxBindingActivator.new(assistant: assistant, inbox: inbox).call
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending,
                                         assignee_agent_bot: connection.agent_bot)
    conversation.contact.update!(
      name: 'Noomi Private', email: 'noomi@example.com', phone_number: '+15551234567', identifier: 'private-contact-id'
    )
    { account: account, workspace: workspace, inbox: inbox, connection: connection, conversation: conversation }
  end

  def create_history(context)
    create_message(context, :incoming, 'Earlier customer', sender: context[:conversation].contact)
    create_message(context, :outgoing, 'Human answer', sender: create(:user, account: context[:account]))
    create_message(context, :template, 'Native greeting')
    create_message(context, :outgoing, 'Automation answer', content_attributes: { automation_rule_id: 17 })
    create_message(context, :outgoing, 'Managed AI answer', sender: context[:connection].agent_bot)
    create_message(context, :outgoing, 'External bot answer', sender: create(:agent_bot, account: context[:account]))
    create_message(context, :outgoing, 'Private note', sender: create(:user, account: context[:account]), private: true)
  end

  def create_message(context, message_type, content, attributes = {})
    create(
      :message,
      **context.slice(:account, :inbox, :conversation),
      message_type: message_type,
      content: content,
      **attributes
    )
  end

  def trigger_turn(context)
    conversation = context.fetch(:conversation)
    message = ChatRing::ConversationWriteBoundary.new(conversation: conversation).call do
      create(:message, account: context.fetch(:account), inbox: context.fetch(:inbox), conversation: conversation,
                       message_type: :incoming, sender: conversation.contact, private: false, content: 'Current question')
    end
    EventDispatcherJob.perform_now(Message::MESSAGE_CREATED, message.created_at, { message: message, performed_by: nil })
    ChatRing::AiTurn.find_by!(workspace: context.fetch(:workspace), conversation: conversation, trigger_message: message)
  end

  def publish_playbook(context)
    actor = create(:user, account: context.fetch(:account), role: :administrator)
    playbook = context.fetch(:workspace).inbox_playbooks.create!(
      inbox: context.fetch(:inbox),
      created_by: actor,
      name: 'Pricing discovery',
      purpose: 'Qualify pricing interest.',
      draft_definition: playbook_definition
    )
    ChatRing::Playbooks::Publisher.new(playbook: playbook, actor: actor, expected_lock_version: 0).call
  end

  def playbook_definition
    {
      trigger_phrases: ['current question'],
      entry_step_id: 'ask_need',
      collected_fields: [{ key: 'need', type: 'string', required: true, native_contact_attribute_key: nil }],
      tool_allowlist: [],
      steps: [
        { id: 'ask_need', kind: 'ask_text', prompt: 'What service do you need?', field_key: 'need', next_step_id: 'complete' },
        { id: 'complete', kind: 'terminal', outcome: 'complete' }
      ],
      safety_rules: { on_human_request: 'native_availability', on_side_question: 'answer_then_resume' }
    }
  end
end
