require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderCleanupScheduler do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:source) { knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available') }
  let(:markdown) { "# Example\n\nUseful knowledge content." }
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
        provider_source_id: 'source-1',
        provider_status: 'ready'
      )
      record.update!(status: 'retired')
    end
  end

  it 'schedules one idempotent cleanup for an inactive provider index' do
    expect do
      described_class.schedule_eligible!(knowledge_base: knowledge_base)
    end.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    cleanup = index.reload.provider_cleanup
    expect(cleanup).to have_attributes(
      provider_source_id: 'source-1',
      binding_digest: index.provider_binding_digest,
      status: 'pending',
      attempts: 0
    )

    clear_enqueued_jobs
    expect do
      described_class.schedule_eligible!(knowledge_base: knowledge_base)
    end.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
  end

  it 'never schedules the active index' do
    index.update!(status: 'active')
    knowledge_base.update!(active_knowledge_index: index)

    expect do
      described_class.schedule_eligible!(knowledge_base: knowledge_base)
    end.not_to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)
    expect(index.provider_cleanup).to be_nil
  end
end
