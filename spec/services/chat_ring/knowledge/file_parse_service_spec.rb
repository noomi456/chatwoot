require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileParseService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }
  let(:parse_token) { SecureRandom.uuid }
  let(:preflight) do
    File.open(sample_pdf, 'rb') do |file|
      ChatRing::Knowledge::FilePreflight.call(
        io: file, filename: 'Guide.pdf', declared_content_type: 'application/pdf'
      )
    end
  end
  let(:source) do
    knowledge_base.file_sources.create!(
      source_kind: 'pdf', original_filename: 'Guide.pdf', content_type: 'application/pdf',
      byte_size: preflight.byte_size, raw_content_hash: preflight.content_hash,
      parser_profile: ChatRing::Knowledge::FirecrawlParseClient.profile_for('pdf'),
      parser_profile_digest: ChatRing::Knowledge::FirecrawlParseClient.profile_digest('pdf'),
      metadata: preflight.metadata, parse_token: parse_token, created_by: actor, approved_by: actor
    ).tap do |record|
      record.file.attach(io: File.open(sample_pdf, 'rb'), filename: 'Guide.pdf', content_type: 'application/pdf')
      knowledge_base.materials.create!(
        file_source: record, source_kind: 'pdf', source_reference: record.source_reference,
        title: 'Guide.pdf', status: 'processing'
      )
    end
  end
  let(:client) { instance_double(ChatRing::Knowledge::FirecrawlParseClient) }

  def parse(source_record = source)
    described_class.new(source_record, client: client, parse_token: source_record.parse_token).call
  end

  before do
    allow(ChatRing::Knowledge::IndexBuilder).to receive(:enqueue!)
  end

  it 'passes the user upload to Firecrawl Parse and updates the same Training Material' do
    allow(client).to receive(:parse).and_return(parsed_payload('First content'))

    expect(parse).to eq(:complete)

    material = source.materials.first.reload
    expect(source.reload).to have_attributes(status: 'ready')
    expect(material).to have_attributes(markdown: include('First content'), status: 'processing')
    expect(ChatRing::Knowledge::IndexBuilder).to have_received(:enqueue!).with(knowledge_base)
    expect(client).to have_received(:parse).once
  end

  it 'always calls Firecrawl Parse again when the user re-runs an available file' do
    allow(client).to receive(:parse).and_return(parsed_payload('First content'), parsed_payload('Updated content'))
    parse

    parse_job = instance_double(ChatRing::Knowledge::FileParseJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later).and_return(parse_job)
    described_class.rerun!(source.reload)
    expect(source.materials.first.reload.status).to eq('updating')
    parse(source.reload)

    expect(client).to have_received(:parse).twice
    expect(source.materials.first.reload.markdown).to include('Updated content')
  end

  it 'keeps the previous extracted content when a user-requested refresh fails' do
    allow(client).to receive(:parse).and_return(parsed_payload('Existing content'))
    parse
    old_markdown = source.materials.first.reload.markdown

    parse_job = instance_double(ChatRing::Knowledge::FileParseJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later).and_return(parse_job)
    described_class.rerun!(source.reload)
    allow(client).to receive(:parse).and_raise(
      ChatRing::Knowledge::FirecrawlParseClient::RequestError.new('Firecrawl unavailable')
    )
    parse(source.reload)

    expect(source.materials.first.reload).to have_attributes(status: 'refresh_failed', markdown: old_markdown)
  end

  it 'ignores a delayed Parse job from an older user command' do
    old_token = source.parse_token
    allow(client).to receive(:parse).and_return(parsed_payload('Existing content'))
    parse
    parse_job = instance_double(ChatRing::Knowledge::FileParseJob, successfully_enqueued?: true)
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later).and_return(parse_job)
    described_class.rerun!(source.reload)

    described_class.new(source.reload, client: client, parse_token: old_token).call

    expect(client).to have_received(:parse).once
    expect(source.reload.status).to eq('refreshing')
  end

  def parsed_payload(text)
    {
      'markdown' => "# Product guide\n\n#{text} with enough product documentation for retrieval and testing.",
      'metadata' => { 'title' => 'Product guide', 'numPages' => 2 }
    }
  end
end
