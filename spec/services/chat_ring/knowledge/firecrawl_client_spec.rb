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

  it 'starts a bounded batch scrape for the exact mapped URLs' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/batch/scrape').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { success: true, id: 'batch-123', url: 'https://api.firecrawl.dev/v2/batch/scrape/batch-123' }.to_json
    )

    urls = ['https://example.com', 'https://example.com/docs/']
    expect(client.start_batch_scrape(urls: urls)).to eq('batch-123')
    request_matcher = have_requested(:post, 'https://api.firecrawl.dev/v2/batch/scrape').with do |request|
      body = JSON.parse(request.body)
      body['urls'] == ['https://example.com/', 'https://example.com/docs'] &&
        body['formats'] == ['markdown'] && body['onlyMainContent'] == true && body['ignoreInvalidURLs'] == false
    end
    expect(WebMock).to request_matcher
  end

  it 'collects every completed batch page from the configured Firecrawl origin' do
    stub_request(:get, 'https://api.firecrawl.dev/v2/batch/scrape/batch-123').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        status: 'completed',
        data: [{ markdown: 'One' }],
        next: 'https://api.firecrawl.dev/v2/batch/scrape/batch-123?skip=1'
      }.to_json
    )
    stub_request(:get, 'https://api.firecrawl.dev/v2/batch/scrape/batch-123?skip=1').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'completed', data: [{ markdown: 'Two' }] }.to_json
    )

    expect(client.batch_status('batch-123')['data'].pluck('markdown')).to eq(%w[One Two])
  end

  it 'rejects a pagination URL that could leak the API credential to another origin' do
    stub_request(:get, 'https://api.firecrawl.dev/v2/batch/scrape/batch-123').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        status: 'completed',
        data: [],
        next: 'https://attacker.example/capture'
      }.to_json
    )

    expect { client.batch_status('batch-123') }.to raise_error(
      described_class::ResponseError,
      /outside the configured API origin/
    )
  end
end
