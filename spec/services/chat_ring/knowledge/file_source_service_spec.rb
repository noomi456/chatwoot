require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileSourceService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }
  let(:parse_job) { instance_double(ChatRing::Knowledge::FileParseJob, successfully_enqueued?: true) }

  before do
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later).and_return(parse_job)
  end

  it 'creates one account Training Material and queues Firecrawl Parse from the user upload' do
    result = described_class.create!(
      account: account,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )

    expect(result.reused).to be(false)
    expect(result.source.file).to be_attached
    expect(result.source.materials.one?).to be(true)
    expect(result.source.materials.first).to have_attributes(status: 'processing', title: 'Guide.pdf')
    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later)
      .with(result.source.id, result.source.parse_token).once
  end

  it 'reuses an identical successful upload without another paid Parse request' do
    first = described_class.create!(
      account: account, uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation', actor: actor
    )
    markdown = '# Parsed guide'
    first.source.update!(
      status: 'ready', markdown: markdown, content_hash: Digest::SHA256.hexdigest(markdown), parsed_at: Time.current
    )
    first.source.materials.first.update!(
      status: 'available', markdown: markdown, content_hash: Digest::SHA256.hexdigest(markdown), extracted_at: Time.current
    )

    second = described_class.create!(
      account: account, uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation', actor: actor
    )

    expect(second).to have_attributes(reused: true, source: first.source)
    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later).once
  end

  it 'does not share a duplicate file record across accounts' do
    other_account = create(:account)
    other_actor = create(:user, account: other_account, role: :administrator)

    first = described_class.create!(
      account: account, uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation', actor: actor
    )
    second = described_class.create!(
      account: other_account, uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation', actor: other_actor
    )

    expect(second.source).not_to eq(first.source)
    expect(second.source.knowledge_base).not_to eq(first.source.knowledge_base)
  end

  def uploaded_pdf
    tempfile = Tempfile.new(['guide', '.pdf'])
    tempfile.binmode
    tempfile.write(File.binread(sample_pdf))
    tempfile.rewind
    Struct.new(:tempfile, :original_filename, :content_type).new(tempfile, 'Guide.pdf', 'application/pdf')
  end
end
