require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileSourceService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:actor) { create(:user) }
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }

  it 'stores one private source and reuses it without another Parse job for an identical upload' do
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later)

    first = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )
    second = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )

    expect(first.reused).to be(false)
    expect(second.reused).to be(true)
    expect(second.source).to eq(first.source)
    expect(first.source.file).to be_attached
    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later).with(first.source.id).once
  end

  it 'rejects a cross-account inbox before creating storage or parse work' do
    other_account = create(:account)

    expect do
      expect do
        described_class.create!(
          account: other_account,
          inbox: inbox,
          uploaded_file: uploaded_pdf,
          authority_class: 'product_documentation',
          actor: actor
        )
      end.to raise_error(described_class::Error, /Inbox does not belong/)
    end.not_to change(ChatRing::KnowledgeFileSource, :count)
  end

  it 'recovers a matching failed record whose private attachment was lost' do
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later)
    first = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )
    first.source.file.purge
    first.source.update!(status: 'failed', failure_code: 'attachment_missing')

    recovered = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'approved_compliance',
      actor: actor
    )

    expect(recovered).to have_attributes(reused: true, source: first.source)
    expect(recovered.source.reload).to have_attributes(status: 'uploaded', authority_class: 'approved_compliance')
    expect(recovered.source.file).to be_attached
    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later).with(first.source.id).twice
  end

  it 'restores an identical disabled source without spending another Parse call' do
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later)
    original = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )
    original.source.file.attach unless original.source.file.attached?
    original.source.update!(status: 'disabled', disabled_at: Time.current)

    restored = described_class.create!(
      account: account,
      inbox: inbox,
      uploaded_file: uploaded_pdf,
      authority_class: 'product_documentation',
      actor: actor
    )

    expect(restored).to have_attributes(reused: true, source: original.source)
    expect(restored.source.reload).to have_attributes(status: 'uploaded', disabled_at: nil)
    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later).with(original.source.id).twice
  end

  def uploaded_pdf
    tempfile = Tempfile.new(['guide', '.pdf'])
    tempfile.binmode
    tempfile.write(File.binread(sample_pdf))
    tempfile.rewind
    Struct.new(:tempfile, :original_filename, :content_type).new(tempfile, 'Guide.pdf', 'application/pdf')
  end
end
