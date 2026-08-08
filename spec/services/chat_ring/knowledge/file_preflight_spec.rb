require 'rails_helper'
require 'zlib'

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
      expect(result.metadata).to eq('original_extension' => '.pdf')
    end
  end

  it 'accepts a structurally valid DOCX upload' do
    with_docx do |file|
      result = described_class.call(
        io: file,
        filename: 'Guide.docx',
        declared_content_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      )

      expect(result).to have_attributes(source_kind: 'docx')
    end
  end

  it 'rejects a ZIP prefix pretending to be DOCX before a paid Parse request' do
    tempfile = Tempfile.new(['knowledge', '.docx'])
    tempfile.binmode
    tempfile.write("PK\x03\x04not-a-word-document".b)
    tempfile.rewind
    allow(Marcel::MimeType).to receive(:for).and_return('application/zip')

    expect do
      described_class.call(io: tempfile, filename: 'Guide.docx')
    end.to raise_error(described_class::Error, /does not match/)
  ensure
    tempfile&.close!
  end

  it 'normalizes HTM and XHTML uploads to the Firecrawl HTML source kind' do
    %w[htm xhtml].each do |extension|
      tempfile = Tempfile.new(['knowledge', ".#{extension}"])
      tempfile.write('<!doctype html><html><body>Knowledge</body></html>')
      tempfile.rewind
      allow(Marcel::MimeType).to receive(:for).with(anything, name: "Guide.#{extension}").and_return('text/html')

      result = described_class.call(io: tempfile, filename: "Guide.#{extension}", declared_content_type: 'text/html')

      expect(result).to have_attributes(source_kind: 'html', content_type: 'text/html')
      tempfile.close!
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
    tempfile.write(
      zip_archive(
        '[Content_Types].xml' => <<~XML,
          <?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types" />
        XML
        'word/document.xml' => <<~XML
          <?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body /></w:document>
        XML
      )
    )
    tempfile.rewind
    allow(Marcel::MimeType).to receive(:for).and_return(
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    )
    yield tempfile
  ensure
    tempfile&.close!
  end

  def zip_archive(entries) # rubocop:disable Metrics/AbcSize
    body = +''.b
    directory = +''.b
    entries.each do |name, content|
      data = content.b
      offset = body.bytesize
      crc = Zlib.crc32(data)
      body << [0x04034b50, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize, name.bytesize, 0].pack('VvvvvvVVVvv')
      body << name.b << data
      directory << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, data.bytesize, data.bytesize,
                    name.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVVvvvvvVV')
      directory << name.b
    end
    body << directory
    body << [0x06054b50, 0, 0, entries.size, entries.size, directory.bytesize,
             body.bytesize - directory.bytesize, 0].pack('VvvvvVVv')
  end
end
