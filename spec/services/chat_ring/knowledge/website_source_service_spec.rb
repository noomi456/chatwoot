require 'rails_helper'

RSpec.describe ChatRing::Knowledge::WebsiteSourceService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:firecrawl) { instance_double(ChatRing::Knowledge::FirecrawlClient) }

  it 'maps, excludes non-core routes, and queues the remaining pages from one Add command' do
    allow(firecrawl).to receive(:map).and_return(
      [
        { 'url' => 'https://example.com/features' },
        { 'url' => 'https://example.com/docs' },
        { 'url' => 'https://example.com/blog/news' },
        { 'url' => 'https://example.com/privacy-policy' }
      ]
    )
    extraction_job = instance_double(ChatRing::Knowledge::WebsiteExtractionJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::WebsiteExtractionJob).to receive(:perform_later).and_return(extraction_job)

    source = described_class.add_website!(
      account: account, root_url: 'https://example.com/', actor: admin, firecrawl: firecrawl
    )

    expect(source.mapped_manifest.find { |entry| entry['url'].end_with?('/features') }).to include('included' => true)
    expect(source.mapped_manifest.find { |entry| entry['url'].end_with?('/docs') }).to include('included' => false)
    expect(source.mapped_manifest.find { |entry| entry['url'].end_with?('/blog/news') }).to include('included' => false)
    expect(source.mapped_manifest.find { |entry| entry['url'].end_with?('/privacy-policy') })
      .to include('included' => false)
    expect(source.materials.active).to contain_exactly(
      an_object_having_attributes(source_reference: 'https://example.com/features', status: 'processing')
    )
    expect(ChatRing::Knowledge::WebsiteExtractionJob).to have_received(:perform_later)
      .with(source.id, ['https://example.com/features'], false, 'batch', source.reload.extraction_token)
  end

  it 'allows a full-site excluded Help page to be added directly' do
    extraction_job = instance_double(ChatRing::Knowledge::WebsiteExtractionJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::WebsiteExtractionJob).to receive(:perform_later).and_return(extraction_job)

    source = described_class.add_webpage!(
      account: account, url: 'https://example.com/help/getting-started', actor: admin
    )

    expect(source.mapped_manifest).to contain_exactly(
      'url' => 'https://example.com/help/getting-started',
      'included' => true,
      'authority_class' => 'product_documentation'
    )
    expect(ChatRing::Knowledge::WebsiteExtractionJob).to have_received(:perform_later)
      .with(source.id, ['https://example.com/help/getting-started'], false, 'single', source.reload.extraction_token)
  end

  it 'scrapes one explicit webpage without calling Firecrawl Map' do
    extraction_job = instance_double(ChatRing::Knowledge::WebsiteExtractionJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::WebsiteExtractionJob).to receive(:perform_later).and_return(extraction_job)

    source = described_class.add_webpage!(
      account: account, url: 'https://example.com/features', actor: admin
    )

    expect(source).to have_attributes(source_type: 'webpage', status: 'extracting')
    expect(source.mapped_manifest).to contain_exactly(
      'url' => 'https://example.com/features',
      'included' => true,
      'authority_class' => 'product_documentation'
    )
    expect(source.materials.active).to contain_exactly(
      an_object_having_attributes(source_reference: 'https://example.com/features', status: 'processing')
    )
    expect(ChatRing::Knowledge::WebsiteExtractionJob).to have_received(:perform_later)
      .with(source.id, ['https://example.com/features'], false, 'single', source.reload.extraction_token)
  end

  it 're-runs only the exact Training Material requested by the user' do
    source = mapped_source
    material = source.materials.create!(
      knowledge_base: source.knowledge_base,
      source_kind: 'website', source_reference: 'https://example.com/docs',
      public_url: 'https://example.com/docs', title: 'Docs', status: 'available',
      markdown: '# Existing', content_hash: Digest::SHA256.hexdigest('# Existing'), extracted_at: Time.current
    )
    extraction_job = instance_double(ChatRing::Knowledge::WebsiteExtractionJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::WebsiteExtractionJob).to receive(:perform_later).and_return(extraction_job)

    described_class.rerun!(material)

    expect(material.reload.status).to eq('updating')
    expect(ChatRing::Knowledge::WebsiteExtractionJob).to have_received(:perform_later)
      .with(source.id, ['https://example.com/docs'], true, 'single', source.reload.extraction_token)
  end

  it 'keeps a user-deleted page excluded when the same full website is mapped again' do
    source = mapped_source
    source.update!(status: 'available')
    source.materials.create!(
      knowledge_base: source.knowledge_base,
      source_kind: 'website', source_reference: 'https://example.com/docs',
      public_url: 'https://example.com/docs', title: 'Docs', status: 'failed',
      deleted_at: Time.current
    )
    allow(firecrawl).to receive(:map).and_return([{ 'url' => 'https://example.com/docs' }])

    remapped = described_class.map!(
      account: account, root_url: 'https://example.com/', actor: admin, firecrawl: firecrawl
    )

    expect(remapped.mapped_manifest).to contain_exactly(
      include(
        'url' => 'https://example.com/docs',
        'included' => false,
        'exclusion_reason' => 'previously_deleted'
      )
    )
  end

  def mapped_source
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    knowledge_base.website_sources.create!(
      root_url: 'https://example.com/', status: 'mapped',
      mapped_manifest: [
        { 'url' => 'https://example.com/docs', 'title' => 'Docs', 'included' => true, 'authority_class' => 'product_documentation' },
        { 'url' => 'https://example.com/privacy-policy', 'included' => false, 'exclusion_reason' => 'non_knowledge_route' }
      ]
    )
  end
end
