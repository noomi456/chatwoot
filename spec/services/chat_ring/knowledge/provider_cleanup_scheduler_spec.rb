require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderCleanupScheduler do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  it 'durably schedules only an unreferenced retired provider version' do
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
      content_hash: 'a' * 64,
      provider_file_name: 'example.md',
      provider_source_id: 'source-1',
      provider_status: 'ready'
    )
    version.update!(status: 'retired')

    expect do
      described_class.schedule_eligible!(account: account, inbox: inbox)
    end.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    cleanup = ChatRing::KnowledgeProviderCleanup.find_by!(knowledge_version: version)
    expect(cleanup).to have_attributes(
      provider_source_id: 'source-1',
      binding_digest: version.evaluation_binding_digest,
      status: 'pending',
      attempts: 0
    )
    expect(cleanup.eligible_at).to be > Time.current

    clear_enqueued_jobs
    expect do
      described_class.schedule_eligible!(account: account, inbox: inbox)
    end.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(cleanup.reload).to have_attributes(status: 'pending', attempts: 0)
  end

  it 'does not schedule a retained rollback target' do
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
      content_hash: 'a' * 64,
      provider_file_name: 'example.md',
      provider_source_id: 'source-retained',
      provider_status: 'ready'
    )
    version.update!(status: 'retired')
    current = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'published',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
    ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: current,
      previous_knowledge_version: version,
      published_at: Time.current
    )

    expect do
      described_class.schedule_eligible!(account: account, inbox: inbox)
    end.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(version.provider_cleanup).to be_nil
  end

  it 'immediately cancels pending deletion when a version becomes protected' do
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
      content_hash: 'a' * 64,
      provider_file_name: 'example.md',
      provider_source_id: 'source-retained',
      provider_status: 'ready'
    )
    version.update!(status: 'retired')
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-retained',
      binding_digest: version.evaluation_binding_digest,
      eligible_at: 1.day.from_now
    )
    current = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'published',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
    ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: current,
      previous_knowledge_version: version,
      published_at: Time.current
    )

    expect do
      described_class.schedule_eligible!(account: account, inbox: inbox)
    end.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(cleanup.reload).to have_attributes(
      status: 'cancelled',
      last_error: 'knowledge version is retained by a publication pointer'
    )
  end
end
