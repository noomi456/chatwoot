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
        body['formats'] == ['markdown'] && body['onlyMainContent'] == true && body['ignoreInvalidURLs'] == true
    end
    expect(WebMock).to request_matcher
  end

  it 'scrapes one explicit webpage directly without Map or batch scrape' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/scrape').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        success: true,
        data: {
          markdown: '# Features',
          metadata: { sourceURL: 'https://example.com/features', statusCode: 200 }
        }
      }.to_json
    )

    result = client.scrape(url: 'https://example.com/features', max_age: 0)

    expect(result).to include('markdown' => '# Features')
    expect(WebMock).to have_requested(:post, 'https://api.firecrawl.dev/v2/scrape').with do |request|
      body = JSON.parse(request.body)
      body == {
        'url' => 'https://example.com/features',
        'formats' => ['markdown'],
        'onlyMainContent' => true,
        'maxAge' => 0
      }
    end.once
    expect(WebMock).not_to have_requested(:post, 'https://api.firecrawl.dev/v2/map')
    expect(WebMock).not_to have_requested(:post, 'https://api.firecrawl.dev/v2/batch/scrape')
  end

  it 'fails rather than publishing a potentially truncated map' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/map').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { success: true, links: [{ url: 'https://example.com/' }, { url: 'https://example.com/docs' }] }.to_json
    )

    expect { client.map(url: 'https://example.com/', limit: 2) }.to raise_error(
      described_class::ResponseError,
      /completeness is unknown/
    )
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

  it 'rejects a repeated pagination URL instead of looping indefinitely' do
    repeated_url = 'https://api.firecrawl.dev/v2/batch/scrape/batch-123?skip=1'
    stub_request(:get, 'https://api.firecrawl.dev/v2/batch/scrape/batch-123').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'completed', data: [], next: repeated_url }.to_json
    )
    stub_request(:get, repeated_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'completed', data: [], next: repeated_url }.to_json
    )

    expect { client.batch_status('batch-123') }.to raise_error(
      described_class::ResponseError,
      /refusing to loop indefinitely/
    )
    expect(WebMock).to have_requested(:get, repeated_url).once
  end

  it 'normalizes transient connection resets into retryable request errors' do
    stub_request(:post, 'https://api.firecrawl.dev/v2/map').to_raise(Errno::ECONNRESET)

    expect { client.map(url: 'https://example.com/') }.to raise_error(
      described_class::RequestError,
      /ECONNRESET/
    )
  end
end
