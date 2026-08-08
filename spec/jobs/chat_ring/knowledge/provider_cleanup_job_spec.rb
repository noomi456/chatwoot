require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderCleanupJob do
  around do |example|
    with_modified_env(
      DOCSGPT_BASE_URL: 'http://docsgpt.internal:7091',
      DOCSGPT_JWT_SECRET: 'jwt-secret',
      DOCSGPT_INTERNAL_KEY: 'internal-key',
      DOCSGPT_SERVICE_SECRET: 'service-secret'
    ) { example.run }
  end

  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:index) do
    knowledge_base.knowledge_indexes.create!(
      workspace: knowledge_base.workspace,
      status: 'retired',
      provider: 'docs_gpt',
      provider_release: 'provider-release',
      mapped_manifest: [],
      manifest_digest: Digest::SHA256.hexdigest([].to_json),
      config_snapshot: {}
    )
  end
  let(:cleanup) do
    ChatRing::KnowledgeProviderCleanup.create!(
      knowledge_index: index,
      knowledge_base: knowledge_base,
      account_id: account.id,
      provider_source_id: 'source-1',
      binding_digest: 'a' * 64,
      eligible_at: 1.minute.ago
    )
  end
  let(:client) { instance_double(ChatRing::Knowledge::DocsGptClient, delete_source: { 'status' => 'deleted' }) }

  it 'idempotently deletes the inactive provider source' do
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)

    described_class.perform_now(cleanup.id)

    expect(cleanup.reload).to have_attributes(status: 'succeeded', attempts: 1, last_error: nil)
    expect(client).to have_received(:delete_source).with(
      account_id: account.id,
      knowledge_index_id: index.id,
      binding_digest: 'a' * 64,
      source_id: 'source-1'
    )
  end

  it 'cancels deletion when the index is active' do
    index.update!(status: 'active')
    knowledge_base.update!(active_knowledge_index: index)
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)

    described_class.perform_now(cleanup.id)

    expect(cleanup.reload.status).to eq('cancelled')
    expect(client).not_to have_received(:delete_source)
  end
end
