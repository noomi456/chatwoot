require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileParseService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:actor) { create(:user) }
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }
  let(:preflight) do
    File.open(sample_pdf, 'rb') do |file|
      ChatRing::Knowledge::FilePreflight.call(io: file, filename: 'Guide.pdf', declared_content_type: 'application/pdf')
    end
  end
  let(:source) do
    ChatRing::KnowledgeFileSource.create!(
      account: account,
      inbox: inbox,
      source_kind: 'pdf',
      original_filename: 'Guide.pdf',
      content_type: 'application/pdf',
      byte_size: preflight.byte_size,
      raw_content_hash: preflight.content_hash,
      parser_profile: ChatRing::Knowledge::FirecrawlParseClient.profile_for('pdf'),
      parser_profile_digest: ChatRing::Knowledge::FirecrawlParseClient.profile_digest('pdf'),
      metadata: preflight.metadata,
      created_by: actor,
      approved_by: actor
    ).tap do |record|
      record.file.attach(io: File.open(sample_pdf, 'rb'), filename: 'Guide.pdf', content_type: 'application/pdf')
    end
  end
  let(:client) { instance_double(ChatRing::Knowledge::FirecrawlParseClient) }

  it 'stores Parse Markdown and makes repeated job delivery free and idempotent' do
    allow(client).to receive(:parse).and_return(
      'markdown' => "# Product guide\n\nThis is complete product documentation with enough meaningful content for retrieval.",
      'metadata' => { 'title' => 'Product guide', 'numPages' => 2 }
    )

    expect(described_class.new(source, client: client).call).to eq(:complete)
    expect(described_class.new(source.reload, client: client).call).to eq(:complete)

    expect(source.reload).to have_attributes(
      status: 'ready',
      content_hash: Digest::SHA256.hexdigest(source.markdown),
      failure_code: nil
    )
    expect(client).to have_received(:parse).with(hash_including(profile: source.parser_profile)).once
  end

  it 'stores file Markdown larger than Chatwoot generic text fields up to the knowledge-document limit' do
    markdown = "# Long product guide\n\n#{'Detailed product guidance. ' * 1000}"
    allow(client).to receive(:parse).and_return(
      'markdown' => markdown,
      'metadata' => { 'title' => 'Long product guide', 'numPages' => 24 }
    )

    expect(described_class.new(source, client: client).call).to eq(:complete)

    expect(source.reload).to have_attributes(status: 'ready', markdown: markdown.strip)
    expect(source.markdown.length).to be > ApplicationRecord::MAX_TEXT_COLUMN_LENGTH
  end

  it 'does not automatically repeat a paid request whose server completion is unknown' do
    error = ChatRing::Knowledge::FirecrawlParseClient::RequestError.new(
      'Firecrawl Parse failed with HTTP 503',
      http_status: 503,
      indeterminate: true
    )
    allow(client).to receive(:parse).and_raise(error)

    expect(described_class.new(source, client: client).call).to eq(:complete)

    expect(source.reload).to have_attributes(status: 'parse_indeterminate')
    expect(client).to have_received(:parse).once
  end
end
