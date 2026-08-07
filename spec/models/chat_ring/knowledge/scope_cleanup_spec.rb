require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ScopeCleanup do
  include ActiveJob::TestHelper

  def create_version(account:, inbox:)
    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
    version.documents.create!(
      source_url: 'https://example.com/',
      markdown: '# Example',
      content_hash: Digest::SHA256.hexdigest('# Example'),
      provider_file_name: 'example.md',
      provider_source_id: "source-#{version.id}",
      provider_status: 'ready'
    )
    version.update!(status: 'published')
    version
  end

  it 'retains an executable provider tombstone when an inbox is destroyed' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    version = create_version(account: account, inbox: inbox)

    expect { inbox.destroy! }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    cleanup = ChatRing::KnowledgeProviderCleanup.find_by!(knowledge_version_id: version.id)
    expect(cleanup).to have_attributes(
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: "source-#{version.id}",
      status: 'pending'
    )
    expect(cleanup.knowledge_version).to be_nil
    expect(ChatRing::KnowledgeVersion.exists?(version.id)).to be(false)
  end

  it 'retains provider tombstones for every knowledge version when an account is destroyed' do
    account = create(:account)
    inbox = create(:inbox, account: account)
    version = create_version(account: account, inbox: inbox)

    expect { account.destroy! }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    cleanup = ChatRing::KnowledgeProviderCleanup.find_by!(knowledge_version_id: version.id)
    expect(cleanup).to have_attributes(account_id: account.id, inbox_id: inbox.id, status: 'pending')
    expect(cleanup.knowledge_version).to be_nil
    expect(ChatRing::KnowledgeVersion.exists?(version.id)).to be(false)
  end
end
