require 'rails_helper'

RSpec.describe ChatRing::Knowledge::VersionComposer do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:actor) { create(:user) }
  let(:website_version) do
    manifest = [{ 'url' => 'https://example.com/docs', 'included' => true }]
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      root_url: 'https://example.com/',
      provider_release: 'provider-release',
      mapped_manifest: manifest,
      manifest_digest: Digest::SHA256.hexdigest(manifest.to_json)
    ).tap do |version|
      markdown = '# Website guide\nWebsite knowledge content.'
      version.documents.create!(
        source_url: 'https://example.com/docs',
        title: 'Website guide',
        markdown: markdown,
        content_hash: Digest::SHA256.hexdigest(markdown),
        provider_file_name: 'docs.md',
        provider_status: 'ready',
        metadata: { 'authority_class' => 'product_documentation' }
      )
      version.update!(status: 'ready', ready_at: Time.current)
    end
  end
  let(:file_source) do
    markdown = "# Uploaded guide\n\nDetailed private file knowledge for the same knowledge base."
    ChatRing::KnowledgeFileSource.create!(
      account: account,
      inbox: inbox,
      status: 'uploaded',
      source_kind: 'pdf',
      original_filename: 'Guide.pdf',
      content_type: 'application/pdf',
      byte_size: File.size(sample_pdf),
      raw_content_hash: Digest::SHA256.file(sample_pdf).hexdigest,
      parser_profile: ChatRing::Knowledge::FirecrawlParseClient.profile_for('pdf'),
      parser_profile_digest: ChatRing::Knowledge::FirecrawlParseClient.profile_digest('pdf'),
      metadata: { 'page_count' => 2, 'title' => 'Uploaded guide' },
      created_by: actor,
      approved_by: actor
    ).tap do |source|
      source.file.attach(io: File.open(sample_pdf, 'rb'), filename: 'Guide.pdf', content_type: 'application/pdf')
      source.update!(
        status: 'ready',
        markdown: markdown,
        content_hash: Digest::SHA256.hexdigest(markdown),
        parsed_at: Time.current
      )
    end
  end
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }

  around do |example|
    with_modified_env(DOCSGPT_SCORE_THRESHOLD: '0.62') { example.run }
  end

  it 'combines website pages and uploaded files before entering the existing DocsGPT sync job' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)

    version = described_class.compose!(
      account: account,
      inbox: inbox,
      base_version: website_version,
      file_sources: [file_source]
    )

    expect(version).to have_attributes(status: 'ingesting', root_url: 'https://example.com/')
    expect(version.documents.order(:source_kind).pluck(:source_kind)).to eq(%w[pdf website])
    expect(version.documents.find_by(source_kind: 'pdf')).to have_attributes(
      source_reference: file_source.source_reference,
      source_url: nil,
      public_url: nil,
      file_source_id: file_source.id,
      provider_status: 'pending'
    )
    expect(version.documents.find_by(source_kind: 'website')).to have_attributes(
      source_reference: 'https://example.com/docs',
      public_url: 'https://example.com/docs',
      provider_status: 'pending'
    )
    expect(version.config_snapshot.dig('retrieval', 'score_threshold')).to eq(0.31)
    expect(ChatRing::Knowledge::SyncJob).to have_received(:perform_later).with(version.id)
  end

  it 'can build a file-only knowledge version without initializing Firecrawl website crawling' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)

    version = described_class.compose!(account: account, inbox: inbox, file_sources: [file_source])

    expect(version).to have_attributes(status: 'ingesting', root_url: nil)
    expect(version.documents.pluck(:source_reference)).to contain_exactly(file_source.source_reference)
  end

  it 'clears the publication when the final material is removed' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    publication = ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: website_version.tap { |version| version.update!(status: 'published', published_at: Time.current) },
      published_at: Time.current
    )

    version = described_class.compose!(
      account: account,
      inbox: inbox,
      base_version: website_version,
      excluded_website_references: ['https://example.com/docs']
    )

    expect(version).to have_attributes(status: 'ready')
    expect(version.documents).to be_empty
    expect(version.config_snapshot['build_mode']).to eq('empty_sources')
    expect(ChatRing::KnowledgePublication.exists?(publication.id)).to be(false)
    expect(ChatRing::Knowledge::SyncJob).not_to have_received(:perform_later)
  end

  it 'keeps existing files through the selected source set instead of copying or deleting them implicitly' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    previous = described_class.compose!(account: account, inbox: inbox, base_version: website_version, file_sources: [file_source])
    previous.documents.update_all(provider_status: 'ready') # rubocop:disable Rails/SkipsModelValidations
    previous.update!(status: 'ready', ready_at: Time.current)

    rebuilt = described_class.compose!(account: account, inbox: inbox, base_version: previous, file_sources: [file_source])

    expect(rebuilt.documents.pluck(:source_reference)).to contain_exactly(
      'https://example.com/docs',
      file_source.source_reference
    )
  end

  it 'rejects a combined website and file corpus above the existing Phase 2A size boundary' do
    stub_const('ChatRing::Knowledge::SourcePolicy::MAX_CORPUS_BYTES', 10)

    expect do
      described_class.compose!(account: account, inbox: inbox, base_version: website_version, file_sources: [file_source])
    end.to raise_error(described_class::Error, /Combined knowledge corpus exceeds/)
  end
end
