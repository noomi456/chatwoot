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
end
