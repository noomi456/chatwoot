require 'rails_helper'

RSpec.describe ChatRing::Playbooks::TurnResolver do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:inbox) { create(:channel_widget, account: account).inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  it 'starts the exact published Playbook for the native Inbox and pins its immutable version' do
    version = publish_playbook(inbox: inbox, phrase: 'pricing options')
    message = incoming_message(conversation, '  Pricing options! ')

    result = resolve(message)

    expect(result).to have_attributes(started: true, reason: 'exact_phrase')
    expect(result.execution).to have_attributes(
      workspace: workspace,
      conversation: conversation,
      inbox_playbook_version: version,
      current_step_id: 'ask_need',
      status: 'active',
      last_trigger_message: message
    )
  end

  it 'does not start a Playbook published for another native Inbox' do
    other_inbox = create(:channel_widget, account: account).inbox
    publish_playbook(inbox: other_inbox, phrase: 'pricing options')
    message = incoming_message(conversation, 'Pricing options')

    result = resolve(message)

    expect(result).to have_attributes(execution: nil, started: false, reason: 'no_phrase_match')
  end

  it 'continues the pinned execution after draft or publication state changes' do
    version = publish_playbook(inbox: inbox, phrase: 'pricing options')
    first = resolve(incoming_message(conversation, 'Pricing options')).execution
    version.inbox_playbook.update!(status: :disabled)
    follow_up = incoming_message(conversation, 'Installation cost?')

    result = resolve(follow_up)

    expect(result).to have_attributes(execution: first, started: false, reason: 'active_execution')
    expect(first.reload).to have_attributes(
      inbox_playbook_version: version,
      current_step_id: 'ask_need',
      last_trigger_message: follow_up
    )
  end

  private

  def resolve(message)
    Account.transaction do
      Account.lock.find(account.id)
      Inbox.lock.find(inbox.id)
      Conversation.lock.find(conversation.id)
      described_class.new(message: message, workspace: workspace).call
    end
  end

  def incoming_message(target, content)
    create(
      :message,
      account: account,
      inbox: target.inbox,
      conversation: target,
      sender: target.contact,
      message_type: :incoming,
      private: false,
      content: content
    )
  end

  def publish_playbook(inbox:, phrase:)
    actor = create(:user, account: account, role: :administrator)
    playbook = workspace.inbox_playbooks.create!(
      inbox: inbox,
      created_by: actor,
      name: "Pricing #{inbox.id}",
      purpose: 'Qualify pricing interest.',
      draft_definition: playbook_definition(phrase)
    )
    ChatRing::Playbooks::Publisher.new(playbook: playbook, actor: actor, expected_lock_version: 0).call
  end

  def playbook_definition(phrase)
    {
      trigger_phrases: [phrase],
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
