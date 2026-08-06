require 'rails_helper'

RSpec.describe ChatRing::Knowledge::Retriever do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:provider) { instance_double(ChatRing::Knowledge::DocsGptProvider) }
  let(:validator) { class_double(ChatRing::Knowledge::ProviderValidator, validate!: true) }

  def version_with_document(status: 'ready')
    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
    version.documents.create!(
      source_url: 'https://example.com/',
      markdown: '# Example',
      content_hash: 'a' * 64,
      provider_file_name: "#{version.id}-example.md",
      provider_source_id: "source-#{version.id}",
      provider_source_reference: "/inputs/#{version.id}-example.md",
      provider_status: 'ready',
      metadata: {
        'authority_class' => 'approved_product',
        'headings' => [{ 'level' => 1, 'text' => 'Example', 'path' => 'Example' }],
        'cta_candidates' => [
          { 'label' => 'Book a Demo', 'url' => 'https://example.com/#book-demo', 'heading_path' => 'Example', 'external' => false }
        ]
      }
    )
    version.update!(status: status)
    version
  end

  def mark_evaluated(version)
    version.update!(
      evaluation_status: 'passed',
      evaluated_at: Time.current,
      evaluation_report: { 'binding_digest' => version.evaluation_binding_digest }
    )
  end

  it 'allows an upstream turn to pin and keep using a previously published version' do
    first = version_with_document
    second = version_with_document
    mark_evaluated(first)
    mark_evaluated(second)
    ChatRing::Knowledge::PublicationService.publish!(first, validator: validator)
    pinned_id = described_class.published_version_id(inbox: inbox)
    ChatRing::Knowledge::PublicationService.publish!(second, validator: validator)
    allow(described_class).to receive(:provider).with(first).and_return(provider)
    allow(provider).to receive(:retrieve).and_return(:evidence_set)

    expect(
      described_class.retrieve(inbox: inbox, query: 'Question', knowledge_version_id: pinned_id)
    ).to eq(:evidence_set)
    expect(provider).to have_received(:retrieve).with(
      query: 'Question',
      knowledge_version_id: first.id.to_s,
      source_manifest: described_class.source_manifest(first),
      limit: 5
    )
    manifest_entry = described_class.source_manifest(first).fetch(first.documents.first.provider_source_reference)
    expect(manifest_entry).to include(
      'source_reference' => 'https://example.com/',
      'headings' => [{ 'level' => 1, 'text' => 'Example', 'path' => 'Example' }],
      'cta_candidates' => [
        { 'label' => 'Book a Demo', 'url' => 'https://example.com/#book-demo', 'heading_path' => 'Example', 'external' => false }
      ]
    )
  end

  it 'rejects a same-scope version that was never published' do
    staged = version_with_document

    expect do
      described_class.retrieve(inbox: inbox, query: 'Question', knowledge_version_id: staged.id)
    end.to raise_error(described_class::Error, /never published/)
  end
end
