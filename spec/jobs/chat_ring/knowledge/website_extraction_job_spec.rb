require 'rails_helper'

# The job constructs its Firecrawl client internally; this keeps these examples
# focused on the job's result and stale-command behavior.
# rubocop:disable RSpec/AnyInstance

RSpec.describe ChatRing::Knowledge::WebsiteExtractionJob do
  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:firecrawl) { instance_double(ChatRing::Knowledge::FirecrawlClient) }
  let(:extraction_token) { SecureRandom.uuid }
  let(:source) do
    knowledge_base.website_sources.create!(
      root_url: 'https://example.com/', status: 'extracting', firecrawl_crawl_id: 'crawl-1',
      extraction_token: extraction_token, extraction_started_at: Time.current,
      mapped_manifest: [
        { 'url' => 'https://example.com/good', 'included' => true, 'authority_class' => 'product_documentation' },
        { 'url' => 'https://example.com/missing', 'included' => true, 'authority_class' => 'product_documentation' }
      ]
    ).tap do |website|
      website.materials.create!(
        knowledge_base: knowledge_base, source_kind: 'website', source_reference: 'https://example.com/good',
        public_url: 'https://example.com/good', status: 'processing'
      )
      website.materials.create!(
        knowledge_base: knowledge_base, source_kind: 'website', source_reference: 'https://example.com/missing',
        public_url: 'https://example.com/missing', status: 'processing'
      )
    end
  end

  it 'keeps a successful page when another requested page fails' do
    allow_any_instance_of(described_class).to receive(:firecrawl).and_return(firecrawl)
    allow(firecrawl).to receive(:batch_status).and_return(
      'status' => 'completed',
      'data' => [{
        'markdown' => '# Good\n\nUseful current product information that is long enough for the knowledge base.',
        'metadata' => { 'sourceURL' => 'https://example.com/good', 'title' => 'Good', 'statusCode' => 200 }
      }]
    )
    allow(firecrawl).to receive(:batch_errors).and_return('errors' => [], 'robotsBlocked' => [])
    allow(ChatRing::Knowledge::IndexBuilder).to receive(:enqueue!)

    described_class.perform_now(source.id, source.mapped_manifest.pluck('url'), false, 'batch', extraction_token)

    expect(source.materials.find_by!(source_reference: 'https://example.com/good').status).to eq('processing')
    expect(source.materials.find_by!(source_reference: 'https://example.com/missing').status).to eq('failed')
    expect(ChatRing::Knowledge::IndexBuilder).to have_received(:enqueue!).with(knowledge_base)
  end

  it 'rejects duplicate Firecrawl content without silently selecting material authority' do
    source.materials.find_by!(source_reference: 'https://example.com/missing')
          .update!(source_reference: 'https://example.com/z-alias', public_url: 'https://example.com/z-alias')
    source.update!(
      mapped_manifest: [
        { 'url' => 'https://example.com/good', 'included' => true, 'authority_class' => 'product_documentation' },
        { 'url' => 'https://example.com/z-alias', 'included' => true, 'authority_class' => 'product_documentation' }
      ]
    )
    markdown = '# Shared\n\nUseful current product information that is long enough for the knowledge base.'
    records = %w[good z-alias].map do |path|
      {
        'markdown' => markdown,
        'metadata' => { 'sourceURL' => "https://example.com/#{path}", 'title' => path.titleize, 'statusCode' => 200 }
      }
    end
    allow_any_instance_of(described_class).to receive(:firecrawl).and_return(firecrawl)
    allow(firecrawl).to receive(:batch_status).and_return('status' => 'completed', 'data' => records)
    allow(firecrawl).to receive(:batch_errors).and_return('errors' => [], 'robotsBlocked' => [])
    allow(ChatRing::Knowledge::IndexBuilder).to receive(:enqueue!)

    described_class.perform_now(source.id, source.mapped_manifest.pluck('url'), false, 'batch', extraction_token)

    references = %w[https://example.com/good https://example.com/z-alias]
    expect(source.materials.where(source_reference: references).pluck(:status)).to contain_exactly('failed', 'failed')
    expect(source.reload.crawl_errors.fetch('pages')).to eq(
      [
        {
          'url' => 'https://example.com/good',
          'error' => 'Firecrawl returned duplicate content for https://example.com/good, https://example.com/z-alias'
        },
        {
          'url' => 'https://example.com/z-alias',
          'error' => 'Firecrawl returned duplicate content for https://example.com/good, https://example.com/z-alias'
        }
      ]
    )
    expect(ChatRing::Knowledge::IndexBuilder).not_to have_received(:enqueue!)
  end

  it 'forces Firecrawl freshness only for an explicit user re-run' do
    source.update!(firecrawl_crawl_id: nil, status: 'refreshing')
    allow_any_instance_of(described_class).to receive(:firecrawl).and_return(firecrawl)
    allow(firecrawl).to receive(:scrape).and_return(
      'markdown' => '# Good\n\nUpdated product information that is long enough for the knowledge base.',
      'metadata' => { 'sourceURL' => 'https://example.com/good', 'title' => 'Good', 'statusCode' => 200 }
    )
    allow(ChatRing::Knowledge::IndexBuilder).to receive(:enqueue!)

    described_class.perform_now(source.id, ['https://example.com/good'], true, 'single', extraction_token)

    expect(firecrawl).to have_received(:scrape)
      .with(url: 'https://example.com/good', max_age: 0)
  end

  it 'ignores a delayed job from an older extraction command' do
    allow_any_instance_of(described_class).to receive(:firecrawl).and_return(firecrawl)
    expect(firecrawl).not_to receive(:scrape)

    described_class.perform_now(source.id, ['https://example.com/good'], true, 'single', SecureRandom.uuid)

    expect(source.reload.status).to eq('extracting')
  end
end
# rubocop:enable RSpec/AnyInstance
