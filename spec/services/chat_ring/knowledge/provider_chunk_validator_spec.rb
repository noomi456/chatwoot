require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderChunkValidator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
  end
  let(:reference) { '/inputs/example.md' }
  let(:text) { "\n# Example\n\nUseful content.\n" }
  let(:document) do
    version.documents.create!(
      source_url: 'https://example.com/',
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
