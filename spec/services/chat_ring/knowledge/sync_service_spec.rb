require 'rails_helper'

RSpec.describe ChatRing::Knowledge::SyncService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      root_url: 'https://example.com/',
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66',
      config_snapshot: { 'firecrawl_map_limit' => 5000 }
    )
  end
  let(:firecrawl) { instance_double(ChatRing::Knowledge::FirecrawlClient) }
  let(:docs_gpt) { instance_double(ChatRing::Knowledge::DocsGptClient) }

  it 'filters useless and redundant mapped routes before the paid batch scrape' do
    allow(firecrawl).to receive(:map).and_return(
      [
        { 'url' => 'https://example.com/' },
        { 'url' => 'https://example.com/docs' },
        { 'url' => 'https://example.com/help' },
        { 'url' => 'https://example.com/privacy' },
        { 'url' => 'https://example.com/cookie-policy' },
        { 'url' => 'https://example.com/legal/terms-of-service' },
        { 'url' => 'https://example.com/company/privacy-statement', 'title' => 'Privacy Policy | Example' },
        { 'url' => 'https://example.com/blog/update' },
        { 'url' => 'https://example.com/careers' },
        { 'url' => 'https://example.com/sitemap.xml' },
        { 'url' => 'https://example.com/login' }
      ]
    )
    expect(firecrawl).to receive(:start_batch_scrape).with(
      urls: ['https://example.com/', 'https://example.com/docs']
    ).and_return('batch-1')

    outcome = described_class.new(version, firecrawl: firecrawl, docs_gpt: docs_gpt).tick

    expect(outcome).to eq(:retry)
    expect(version.reload.status).to eq('crawling')
    expect(version.mapped_manifest.count { |entry| entry['included'] }).to eq(2)
    expect(version.mapped_manifest.count { |entry| !entry['included'] }).to eq(9)
  end

  it 'does not start a second build while another worker holds the version lease' do
    version.update!(processing_lease_token: SecureRandom.uuid, processing_lease_expires_at: 5.minutes.from_now)
    expect(firecrawl).not_to receive(:map)

    outcome = described_class.new(version, firecrawl: firecrawl, docs_gpt: docs_gpt).tick

    expect(outcome).to eq(:retry)
    expect(version.reload.status).to eq('pending')
  end

  it 'refuses automatic publication before the retrieval evaluation gate' do
    expect do
      described_class.start!(account: account, inbox: inbox, root_url: 'https://example.com', publish_on_ready: true)
    end.to raise_error(ArgumentError, /publish_on_ready is disabled/)
  end

  it 'rebuilds an isolated provider version from the stored snapshot without calling Firecrawl' do
    markdown = "# Pricing\nUseful pricing information for customers.\n[Start Trial](/signup)"
    manifest = [{ 'url' => 'https://example.com/pricing', 'included' => true }]
    version.update!(mapped_manifest: manifest, manifest_digest: Digest::SHA256.hexdigest(manifest.to_json))
    version.documents.create!(
      source_url: 'https://example.com/pricing',
      title: 'Pricing',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      provider_file_name: 'pricing.md',
      provider_source_id: 'old-source',
      provider_source_reference: '/inputs/pricing.md',
      provider_status: 'ready',
      metadata: { 'authority_class' => 'structured_commercial' }
    )
    version.update!(status: 'published')
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)

    with_modified_env DOCSGPT_SCORE_THRESHOLD: '0.62' do
      rebuilt = described_class.rebuild_from!(version)

      expect(rebuilt).to have_attributes(status: 'ingesting', account: account, inbox: inbox)
      expect(rebuilt.config_snapshot['source_policy_version']).to eq(ChatRing::Knowledge::SourcePolicy::VERSION)
      expect(rebuilt.config_snapshot).to include(
        'build_mode' => 'stored_snapshot_rebuild',
        'source_knowledge_version_id' => version.id
      )
      expect(rebuilt.documents.first).to have_attributes(provider_status: 'pending', provider_source_id: nil)
      expect(rebuilt.documents.first.metadata.fetch('headings')).to include(
        'level' => 1,
        'text' => 'Pricing',
        'path' => 'Pricing'
      )
      expect(rebuilt.documents.first.metadata.fetch('cta_candidates')).to contain_exactly(
        {
          'label' => 'Start Trial',
          'url' => 'https://example.com/signup',
          'heading_path' => 'Pricing',
          'external' => false
        }
      )
      expect(ChatRing::Knowledge::SyncJob).to have_received(:perform_later).with(rebuilt.id)
    end
  end

  it 'rejects a stored snapshot whose content no longer matches its hash' do
    version.update!(manifest_digest: Digest::SHA256.hexdigest(version.mapped_manifest.to_json))
    version.documents.create!(
      source_url: 'https://example.com/',
      title: 'Example',
      markdown: '# Tampered snapshot',
      content_hash: 'a' * 64,
      provider_file_name: 'example.md',
      provider_status: 'ready'
    )
    version.update!(status: 'ready')

    with_modified_env DOCSGPT_SCORE_THRESHOLD: '0.62' do
      expect { described_class.rebuild_from!(version) }.to raise_error(
        described_class::IncompleteCrawlError,
        /does not match its content hash/
      )
    end
  end

  it 'rejects an uploaded provider source containing an unexpected document reference before marking documents ready' do
    document = version.documents.create!(
      source_url: 'https://example.com/pricing',
      title: 'Pricing',
      markdown: '# Pricing',
      content_hash: Digest::SHA256.hexdigest('# Pricing'),
      provider_file_name: 'pricing.md'
    )
    version.update!(status: 'ingesting')
    allow(docs_gpt).to receive(:chunks).and_return(
      [
        { 'metadata' => { 'source' => '/inputs/pricing.md' } },
        { 'metadata' => { 'source' => '/inputs/unexpected.md' } }
      ]
    )

    service = described_class.new(version, firecrawl: firecrawl, docs_gpt: docs_gpt)
    expect { service.send(:finalize_version, [document]) }.to raise_error(
      described_class::ProviderIngestionError,
      /outside the knowledge-version manifest/
    )
    expect(document.reload).to have_attributes(provider_status: 'pending', provider_source_reference: nil)
  end
end
