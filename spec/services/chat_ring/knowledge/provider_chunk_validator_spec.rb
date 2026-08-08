require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderChunkValidator do
  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:source) { knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available') }
  let(:reference) { '/inputs/example.md' }
  let(:text) { "\n# Example\n\nUseful content.\n" }
  let(:material) do
    knowledge_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: 'https://example.com/',
      public_url: 'https://example.com/',
      status: 'processing',
      markdown: text,
      content_hash: Digest::SHA256.hexdigest(text),
      extracted_at: Time.current
    )
  end
  let(:index) do
    knowledge_base.knowledge_indexes.create!(
      workspace: knowledge_base.workspace,
      status: 'building',
      provider_release: 'provider-release',
      mapped_manifest: [],
      manifest_digest: Digest::SHA256.hexdigest([].to_json)
    )
  end
  let(:document) do
    index.documents.create!(
      knowledge_material: material,
      source_kind: 'website',
      source_reference: 'https://example.com/',
      source_url: 'https://example.com/',
      public_url: 'https://example.com/',
      markdown: text,
      content_hash: Digest::SHA256.hexdigest(text),
      provider_file_name: 'example.md',
      metadata: { 'headings' => [{ 'level' => 1, 'text' => 'Example', 'path' => 'Example' }] }
    )
  end
  let(:chunk) do
    {
      'text' => text,
      'metadata' => {
        'source' => reference,
        'chatring_document_id' => Digest::SHA256.hexdigest(reference),
        'chatring_chunk_index' => 0,
        'chatring_content_hash' => Digest::SHA256.hexdigest(text),
        'chatring_heading_path' => 'Example'
      }
    }
  end

  it 'accepts contiguous, content-bound chunks with a source heading path' do
    result = described_class.validate!(documents: [document], chunks: [chunk])

    expect(result).to eq(document => reference)
  end

  it 'rejects headed source content whose provider chunks lost their heading paths' do
    chunk['metadata']['chatring_heading_path'] = ''

    expect do
      described_class.validate!(documents: [document], chunks: [chunk])
    end.to raise_error(described_class::Error, /lost heading paths/)
  end

  it 'rejects a provider chunk whose text no longer matches its stable content hash' do
    chunk['text'] = 'Tampered content'

    expect do
      described_class.validate!(documents: [document], chunks: [chunk])
    end.to raise_error(described_class::Error, /content hash does not match/)
  end

  it 'rejects duplicate stable chunk identities' do
    expect do
      described_class.validate!(documents: [document], chunks: [chunk, chunk.deep_dup])
    end.to raise_error(described_class::Error, /duplicate chunk identities/)
  end
end
