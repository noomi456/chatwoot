require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderCleanupReconciler do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
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
    version.update!(status: 'abandoned', abandoned_at: Time.current, abandon_reason: 'test candidate')
    version
  end

  it 'recreates missing cleanup work for an unprotected terminal version' do
    version

    expect { described_class.call }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(version.reload.provider_cleanup).to be_present
  end

  it 'recovers an expired owner lease and enqueues the due cleanup' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      next_attempt_at: 1.day.ago,
      status: 'retrying',
      lease_token: 'stale-owner',
      lease_expires_at: 1.minute.ago
    )

    expect { described_class.call }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    expect(cleanup.reload).to have_attributes(
      status: 'pending',
      lease_token: nil,
      lease_expires_at: nil,
      last_error: 'expired cleanup lease recovered'
    )
  end

  it 're-enqueues due work only after the last enqueue can be considered lost' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      next_attempt_at: 1.day.ago,
      last_enqueued_at: 31.minutes.ago
    )

    expect { described_class.call }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(cleanup.reload.last_enqueued_at).to be > 1.minute.ago
  end

  it 'reports only due cleanup work whose previous enqueue has made no progress' do
    ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      next_attempt_at: 1.day.ago,
      last_enqueued_at: 5.minutes.ago
    )

    expect(described_class.report.fetch(:overdue_pending_cleanups)).to eq(0)
  end

  it 'does not create an infinite retry loop for exhausted cleanup failures' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      next_attempt_at: 1.day.ago,
      status: 'failed',
      attempts: ChatRing::Knowledge::ProviderCleanupJob::MAX_ATTEMPTS
    )

    expect { described_class.call }.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(cleanup.reload.status).to eq('failed')
  end

  it 'relies on the database to reject a retrying state without an owner lease' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago
    )
    expect do
      cleanup.update_columns(status: 'retrying', lease_token: nil, lease_expires_at: nil) # rubocop:disable Rails/SkipsModelValidations
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it 'allows an explicit operator retry to start a new bounded attempt series' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      status: 'failed',
      attempts: ChatRing::Knowledge::ProviderCleanupJob::MAX_ATTEMPTS
    )

    expect do
      ChatRing::Knowledge::ProviderCleanupScheduler.retry_failed!(cleanup)
    end.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    expect(cleanup.reload).to have_attributes(status: 'pending', attempts: 0, manual_retry_count: 1)
  end

  it 'refuses an operator retry after a version becomes publication-protected' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.day.ago,
      status: 'failed',
      attempts: ChatRing::Knowledge::ProviderCleanupJob::MAX_ATTEMPTS
    )
    current = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'published',
      provider_release: 'provider-release',
      root_url: 'https://example.com/current'
    )
    ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: current,
      previous_knowledge_version: version,
      published_at: Time.current
    )

    expect do
      ChatRing::Knowledge::ProviderCleanupScheduler.retry_failed!(cleanup)
    end.to raise_error(ArgumentError, /publication-protected/)
  end
end
