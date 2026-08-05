require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FirecrawlClient do
  subject(:client) { described_class.new(api_key: 'firecrawl-test-key') }

  it 'maps the root and normalizes duplicate URLs before crawling' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/map').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        success: true,
        links: [
          { url: 'https://example.com/docs/', title: 'Docs' },
          { url: 'https://example.com/docs#top', title: 'Duplicate' }
        ]
      }.to_json
    )

    expect(client.map(url: 'https://example.com/')).to eq(
      [
        { 'url' => 'https://example.com/' },
        { 'url' => 'https://example.com/docs', 'title' => 'Docs' }
      ]
    )
  end

  it 'starts a bounded crawl that extracts Markdown after mapping' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/crawl').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { success: true, id: 'crawl-123', url: 'https://api.firecrawl.dev/v2/crawl/crawl-123' }.to_json
    )

    expect(client.start_crawl(url: 'https://example.com', limit: 2)).to eq('crawl-123')
    expect(WebMock).to have_requested(:post, 'https://api.firecrawl.dev/v2/crawl').with do |request|
      body = JSON.parse(request.body)
      body['url'] == 'https://example.com/' && body['limit'] == 2 &&
        body.dig('scrapeOptions', 'formats') == ['markdown'] && body['allowExternalLinks'] == false
    end
  end

  it 'collects every completed crawl page from the configured Firecrawl origin' do
    stub_request(:get, 'https://api.firecrawl.dev/v2/crawl/crawl-123').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        status: 'completed',
        data: [{ markdown: 'One' }],
        next: 'https://api.firecrawl.dev/v2/crawl/crawl-123?skip=1'
      }.to_json
    )
    stub_request(:get, 'https://api.firecrawl.dev/v2/crawl/crawl-123?skip=1').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'completed', data: [{ markdown: 'Two' }] }.to_json
    )

    expect(client.crawl_status('crawl-123')['data'].pluck('markdown')).to eq(%w[One Two])
  end

  it 'rejects a pagination URL that could leak the API credential to another origin' do
    stub_request(:get, 'https://api.firecrawl.dev/v2/crawl/crawl-123').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        status: 'completed',
        data: [],
        next: 'https://attacker.example/capture'
      }.to_json
    )

    expect { client.crawl_status('crawl-123') }.to raise_error(
      described_class::ResponseError,
      /outside the configured API origin/
    )
  end
end
