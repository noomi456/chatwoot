require 'rails_helper'

RSpec.describe ChatRing::KnowledgeDocument do
  subject(:document) { described_class.new(markdown: markdown) }

  context 'when the source snapshot exceeds Chatwoot generic text length' do
    let(:markdown) { 'a' * 20_001 }

    it 'uses the explicit bounded knowledge-document limit' do
      document.valid?

      expect(document.errors[:markdown]).to be_empty
    end
  end

  context 'when the source snapshot exceeds the knowledge-document limit' do
    let(:markdown) { 'a' * (described_class::MAX_MARKDOWN_LENGTH + 1) }

    it 'rejects the payload' do
      document.valid?

      expect(document.errors[:markdown]).to include('is too long (maximum is 2097152 characters)')
    end
  end

  context 'when its hidden knowledge index is complete' do
    let(:account) { create(:account) }
    let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
    let(:source) { knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available') }
    let(:material) do
      knowledge_base.materials.create!(
        website_source: source,
        source_kind: 'website',
        source_reference: 'https://example.com/',
        public_url: 'https://example.com/',
        status: 'processing',
        markdown: '# Example',
        content_hash: Digest::SHA256.hexdigest('# Example'),
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
    let!(:stored_document) do
      index.documents.create!(
        knowledge_material: material,
        source_kind: 'website',
        source_reference: 'https://example.com/',
        source_url: 'https://example.com/',
        public_url: 'https://example.com/',
        markdown: '# Example',
        content_hash: Digest::SHA256.hexdigest('# Example'),
        provider_file_name: 'example.md',
        provider_status: 'ready'
      )
    end

    before { index.update!(status: 'ready') }

    it 'rejects later source-content mutation' do
      expect(stored_document.update(markdown: '# Changed')).to be(false)
      expect(stored_document.errors[:base]).to include('completed knowledge document snapshot is immutable')
    end

    it 'rejects adding another document to the completed snapshot' do
      added = index.documents.build(
        knowledge_material: material,
        source_kind: 'website',
        source_reference: 'https://example.com/other',
        source_url: 'https://example.com/other',
        public_url: 'https://example.com/other',
        markdown: '# Other',
        content_hash: Digest::SHA256.hexdigest('# Other'),
        provider_file_name: 'other.md'
      )

      expect(added).not_to be_valid
      expect(added.errors[:base]).to include('completed knowledge document snapshot is immutable')
    end
  end
end
