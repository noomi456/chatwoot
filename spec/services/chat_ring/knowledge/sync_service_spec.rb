require 'rails_helper'

RSpec.describe ChatRing::Knowledge::SyncService do
  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:source) { knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available') }
  let(:markdown) { "# Example\n\nUseful product knowledge for customers." }
  let(:material) do
    knowledge_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: 'https://example.com/',
      public_url: 'https://example.com/',
      title: 'Example',
      status: 'processing',
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
        title: material.title,
        markdown: material.markdown,
        content_hash: material.content_hash,
        provider_file_name: 'example.md',
        provider_status: 'pending'
      )
    end
  end
  let(:docs_gpt) { instance_double(ChatRing::Knowledge::DocsGptClient) }

  it 'uploads the catalog once and marks the hidden index ready after provenance validation' do
    document = index.documents.first
    allow(docs_gpt).to receive(:expected_source_id).with(index).and_return('source-1')
    allow(docs_gpt).to receive(:upload_index).with(index).and_return(task_id: 'task-1', source_id: 'source-1')
    allow(docs_gpt).to receive(:task_status).with(index, 'task-1', 'source-1').and_return('status' => 'SUCCESS')
    allow(docs_gpt).to receive(:chunks).with(index, 'source-1').and_return([])
    allow(ChatRing::Knowledge::ProviderChunkValidator).to receive(:validate!)
      .and_return(document => '/inputs/example.md')

    expect(described_class.new(index, docs_gpt: docs_gpt).tick).to eq(:complete)

    expect(index.reload.status).to eq('ready')
    expect(document.reload).to have_attributes(
      provider_status: 'ready',
      provider_source_id: 'source-1',
      provider_source_reference: '/inputs/example.md'
    )
    expect(docs_gpt).to have_received(:upload_index).once
  end

  it 'does not call Firecrawl while indexing already extracted Training Materials' do
    allow(docs_gpt).to receive(:expected_source_id).with(index).and_return('source-1')
    allow(docs_gpt).to receive(:upload_index).and_return(task_id: 'task-1', source_id: 'source-1')
    allow(docs_gpt).to receive(:task_status).with(index, 'task-1', 'source-1').and_return('status' => 'PENDING')

    expect(described_class.new(index, docs_gpt: docs_gpt).tick).to eq(:retry)
    expect(WebMock).not_to have_requested(:post, /api\.firecrawl\.dev/)
  end
end
