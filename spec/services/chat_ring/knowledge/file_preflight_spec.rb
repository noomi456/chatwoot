require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FilePreflight do
  let(:sample_pdf) { Rails.root.join('spec/assets/sample.pdf') }

  it 'accepts a real PDF before Parse' do
    File.open(sample_pdf, 'rb') do |file|
      result = described_class.call(io: file, filename: 'Guide.pdf', declared_content_type: 'application/pdf')

      expect(result).to have_attributes(
        source_kind: 'pdf',
        filename: 'Guide.pdf',
        content_type: 'application/pdf',
        byte_size: File.size(sample_pdf),
        content_hash: Digest::SHA256.file(sample_pdf).hexdigest
      )
      expect(result.metadata).to eq({})
    end
  end

  it 'accepts a DOCX upload' do
    with_docx do |file|
      result = described_class.call(
        io: file,
        filename: 'Guide.docx',
        declared_content_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      )

      expect(result).to have_attributes(source_kind: 'docx')
    end
  end

  it 'rejects an archive renamed to PDF before any paid request' do
    with_docx do |file|
      expect do
        described_class.call(io: file, filename: 'not-a-pdf.pdf', declared_content_type: 'application/pdf')
      end.to raise_error(described_class::Error, /does not match/)
    end
  end

  it 'rejects a filename containing multipart header controls before any paid request' do
    File.open(sample_pdf, 'rb') do |file|
      expect do
        described_class.call(io: file, filename: "Guide\r\nInjected.pdf", declared_content_type: 'application/pdf')
      end.to raise_error(described_class::Error, /filename is invalid/)
    end
  end

  it 'rejects an oversized file before parsing its contents' do
    File.open(sample_pdf, 'rb') do |file|
      allow(File).to receive(:size).with(file.path).and_return(described_class::MAX_FILE_SIZE + 1)

      expect do
        described_class.call(io: file, filename: 'Guide.pdf', declared_content_type: 'application/pdf')
      end.to raise_error(described_class::Error, /exceeds 50 MB/)
    end
  end

  def with_docx
    tempfile = Tempfile.new(['knowledge', '.docx'])
    tempfile.binmode
    tempfile.write("PK\x03\x04".b)
    tempfile.write('DOCX fixture content')
    tempfile.rewind
    yield tempfile
  ensure
    tempfile&.close!
  end
end
