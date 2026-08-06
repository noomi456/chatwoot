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
        { 'url' => 'https://example.com/sitemap' },
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
end
