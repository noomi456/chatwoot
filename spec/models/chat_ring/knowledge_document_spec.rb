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

  context 'when its knowledge version is complete' do
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
    let!(:stored_document) do
      version.documents.create!(
        source_url: 'https://example.com/',
        markdown: '# Example',
        content_hash: Digest::SHA256.hexdigest('# Example'),
        provider_file_name: 'example.md',
        provider_status: 'ready'
      )
    end

    before { version.update!(status: 'ready') }

    it 'rejects later source-content mutation' do
      expect(stored_document.update(markdown: '# Changed')).to be(false)
      expect(stored_document.errors[:base]).to include('completed knowledge document snapshot is immutable')
    end

    it 'rejects adding another document to the completed snapshot' do
      added = version.documents.build(
        source_url: 'https://example.com/other',
        markdown: '# Other',
        content_hash: Digest::SHA256.hexdigest('# Other'),
        provider_file_name: 'other.md'
      )

      expect(added).not_to be_valid
      expect(added.errors[:base]).to include('completed knowledge document snapshot is immutable')
    end
  end
end
