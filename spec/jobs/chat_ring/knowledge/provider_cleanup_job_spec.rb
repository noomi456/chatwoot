require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderCleanupJob do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env(
      DOCSGPT_BASE_URL: 'http://docsgpt.internal:7091',
      DOCSGPT_JWT_SECRET: 'jwt-secret',
      DOCSGPT_INTERNAL_KEY: 'internal-key',
      DOCSGPT_SERVICE_SECRET: 'service-secret'
    ) { example.run }
  end

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'retired',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
  end
  let(:client) { instance_double(ChatRing::Knowledge::DocsGptClient, delete_source: { 'status' => 'deleted' }) }

  it 'idempotently records successful provider deletion' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago
    )
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)

    described_class.perform_now(cleanup.id)

    expect(cleanup.reload).to have_attributes(status: 'succeeded', attempts: 1, last_error: nil)
    expect(cleanup.cleaned_at).to be_present
    expect(client).to have_received(:delete_source).with(
      account_id: account.id,
      knowledge_version_id: version.id,
      binding_digest: 'a' * 64,
      source_id: 'source-1'
    )
  end

  it 'cancels deletion if the version becomes a rollback target' do
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
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago
    )

    described_class.perform_now(cleanup.id)

    expect(cleanup.reload.status).to eq('cancelled')
    expect(client).not_to have_received(:delete_source)
  end

  it 'runs provider deletion outside a database transaction and schedules a durable retry' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago
    )
    error = ChatRing::Knowledge::DocsGptClient::RequestError.new('provider unavailable')
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    allow(client).to receive(:delete_source) do
      expect(ActiveRecord::Base.connection.open_transactions).to eq(baseline_transactions)
      raise error
    end
    job = described_class.new
    allow(job).to receive(:docs_gpt_client).and_return(client)

    expect { job.perform(cleanup.id) }.to have_enqueued_job(described_class)

    expect(cleanup.reload).to have_attributes(
      status: 'pending',
      attempts: 1,
      last_error: 'provider unavailable',
      lease_token: nil,
      lease_expires_at: nil
    )
    expect(cleanup.next_attempt_at).to be > Time.current
  end

  it 'does not let a stale worker complete a lease acquired by a newer worker' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago
    )
    allow(client).to receive(:delete_source) do
      cleanup.reload.update!(
        status: 'retrying',
        lease_token: 'new-owner-token',
        lease_expires_at: 5.minutes.from_now
      )
      { 'status' => 'already_absent' }
    end
    job = described_class.new
    allow(job).to receive(:docs_gpt_client).and_return(client)

    job.perform(cleanup.id)

    expect(cleanup.reload).to have_attributes(
      status: 'retrying',
      lease_token: 'new-owner-token',
      cleaned_at: nil
    )
  end

  it 'does not duplicate deletion while another unexpired lease owns the cleanup' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago,
      status: 'retrying',
      lease_token: 'active-owner',
      lease_expires_at: 5.minutes.from_now
    )
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)

    described_class.perform_now(cleanup.id)

    expect(client).not_to have_received(:delete_source)
    expect(cleanup.reload.lease_token).to eq('active-owner')
  end

  it 'stops automatic retries after the bounded attempt limit' do
    cleanup = ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_version: version,
      account_id: account.id,
      inbox_id: inbox.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago,
      attempts: described_class::MAX_ATTEMPTS - 1
    )
    error = ChatRing::Knowledge::DocsGptClient::RequestError.new('permanent provider failure')
    allow(client).to receive(:delete_source).and_raise(error)
    job = described_class.new
    allow(job).to receive(:docs_gpt_client).and_return(client)

    expect { job.perform(cleanup.id) }.not_to have_enqueued_job(described_class)

    expect(cleanup.reload).to have_attributes(
      status: 'failed',
      attempts: described_class::MAX_ATTEMPTS,
      last_error: 'permanent provider failure',
      lease_token: nil
    )
  end
end
