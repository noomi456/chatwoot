require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ScopeCleanup do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:source) { knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available') }
  let(:markdown) { "# Example\n\nUseful knowledge." }
  let(:material) do
    knowledge_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: 'https://example.com/',
      public_url: 'https://example.com/',
      status: 'available',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      extracted_at: Time.current
    )
  end
  let(:index) do
    knowledge_base.knowledge_indexes.create!(
      workspace: knowledge_base.workspace,
      status: 'building',
      provider: 'docs_gpt',
      provider_release: 'provider-release',
      mapped_manifest: [],
      manifest_digest: Digest::SHA256.hexdigest([].to_json),
      config_snapshot: {}
    ).tap do |record|
      record.documents.create!(
        knowledge_material: material,
        source_kind: 'website',
        source_reference: material.source_reference,
        source_url: material.public_url,
        public_url: material.public_url,
        markdown: material.markdown,
        content_hash: material.content_hash,
        provider_file_name: 'example.md',
        provider_source_id: "source-#{record.id}",
        provider_status: 'ready'
      )
      record.update!(status: 'active')
      knowledge_base.update!(active_knowledge_index: record)
    end
  end

  it 'does not delete the account knowledge base when one inbox is destroyed' do
    inbox = create(:inbox, account: account)
    index

    expect { inbox.destroy! }.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    expect(ChatRing::KnowledgeBase.exists?(knowledge_base.id)).to be(true)
    expect(ChatRing::KnowledgeIndex.exists?(index.id)).to be(true)
  end

  it 'retains an executable provider tombstone when the owning account is destroyed' do
    index

    expect { account.destroy! }.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    cleanup = ChatRing::KnowledgeProviderCleanup.find_by!(knowledge_index_id: index.id)
    expect(cleanup).to have_attributes(account_id: account.id, status: 'pending')
    expect(cleanup.knowledge_index).to be_nil
    expect(ChatRing::KnowledgeIndex.exists?(index.id)).to be(false)
  end
end
