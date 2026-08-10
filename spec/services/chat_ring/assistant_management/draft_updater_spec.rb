require 'rails_helper'

RSpec.describe ChatRing::AssistantManagement::DraftUpdater do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:assistant) { workspace.assistants.create!(name: 'Website Sales') }

  it 'rejects an update when archive wins the Account lock' do
    draft = assistant.create_configuration_draft!(knowledge_scope: scope)
    archive_started = Queue.new
    allow_archive_to_commit = Queue.new

    archiver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        account.reload.with_lock do
          assistant.reload.update!(status: :archived)
          archive_started << true
          allow_archive_to_commit.pop
        end
      end
    end
    archive_started.pop
    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(
          assistant: assistant.reload,
          expected_lock_version: draft.lock_version,
          attributes: { instructions: 'must not persist' }
        ).call
      end
    rescue StandardError => e
      e
    end
    allow_archive_to_commit << true

    archiver.join
    expect(updater.value).to be_a(ActiveRecord::RecordInvalid)
    expect(draft.reload.instructions).to be_blank
  end
end
