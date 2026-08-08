require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FirecrawlParseClient do
  subject(:client) { described_class.new(api_key: 'firecrawl-secret', base_url: 'https://firecrawl.example') }

  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }
  let(:endpoint) { 'https://firecrawl.example/v2/parse' }

  it 'uploads one private file with the locked Parse profile and returns normalized provider data' do
    request = stub_request(:post, endpoint).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: {
        success: true,
        data: { markdown: "# Guide\nUseful content.", metadata: { title: 'Guide', numPages: 2 } }
      }.to_json
    )

    result = client.parse(
      path: sample_pdf.to_s,
      filename: 'Guide.pdf',
      content_type: 'application/pdf',
      source_kind: 'pdf'
    )

    expect(result).to include('markdown' => "# Guide\nUseful content.")
    expect(request).to have_been_requested.once
    expectation = have_requested(:post, endpoint).with do |http_request|
      http_request.headers['Authorization'] == 'Bearer firecrawl-secret' &&
        http_request.headers['Content-Type'].start_with?('multipart/form-data;') &&
        http_request.body.include?('Guide.pdf') &&
        http_request.body.include?('zeroDataRetention') &&
        http_request.body.include?('maxPages')
    end
    expect(WebMock).to expectation
  end

  it 'binds the ZDR entitlement setting into the stored parse profile and digest' do
    without_zdr = nil
    without_zdr_digest = nil
    with_modified_env(FIRECRAWL_ZERO_DATA_RETENTION: 'false') do
      without_zdr = described_class.profile_for('pdf')
      without_zdr_digest = described_class.profile_digest('pdf')
    end

    with_modified_env(FIRECRAWL_ZERO_DATA_RETENTION: 'true') do
      expect(described_class.profile_for('pdf')).to include('zeroDataRetention' => true)
      expect(described_class.profile_digest('pdf')).not_to eq(without_zdr_digest)
    end
    expect(without_zdr).to include('zeroDataRetention' => false)
  end

  it 'marks server failures as indeterminate because Parse has no request idempotency key' do
    stub_request(:post, endpoint).to_return(status: 503, body: 'unavailable')

    expect do
      client.parse(path: sample_pdf.to_s, filename: 'Guide.pdf', content_type: 'application/pdf', source_kind: 'pdf')
    end.to raise_error(described_class::RequestError) { |error| expect(error.indeterminate?).to be(true) }
  end

  it 'marks a definitive validation rejection as safely retryable after correction' do
    stub_request(:post, endpoint).to_return(status: 422, body: '{}')

    expect do
      client.parse(path: sample_pdf.to_s, filename: 'Guide.pdf', content_type: 'application/pdf', source_kind: 'pdf')
    end.to raise_error(described_class::RequestError) { |error| expect(error.indeterminate?).to be(false) }
  end
end
