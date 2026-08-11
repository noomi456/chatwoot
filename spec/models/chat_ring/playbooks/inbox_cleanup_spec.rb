require 'rails_helper'

RSpec.describe ChatRing::Playbooks::InboxCleanup do
  it 'removes only the subordinate Playbook runtime before native Inbox deletion' do
    context = ChatRing::Playbooks::InitialQuestionPreparerSpecSupport.build
    turn = context.fetch(:turn)
    inbox = turn.conversation.inbox
    other_inbox = create(:channel_widget, account: inbox.account).inbox
    execution_id = turn.inbox_playbook_execution_id
    playbook = turn.inbox_playbook_execution.inbox_playbook_version.inbox_playbook
    version_id = playbook.current_version_id

    expect { inbox.destroy! }.not_to raise_error

    expect(ChatRing::AiTurn.exists?(turn.id)).to be(false)
    expect(ChatRing::InboxPlaybookExecution.exists?(execution_id)).to be(false)
    expect(ChatRing::InboxPlaybookVersion.exists?(version_id)).to be(false)
    expect(ChatRing::InboxPlaybook.exists?(playbook.id)).to be(false)
    expect(Inbox.exists?(other_inbox.id)).to be(true)
  end
end
