require 'digest'
require 'marcel'
require 'pathname'

class ChatRing::Knowledge::FilePreflight
  MAX_FILE_SIZE = ChatRing::KnowledgeFileSource::MAX_FILE_SIZE
  MAX_FILENAME_LENGTH = 255
  CONTENT_TYPES = {
    'pdf' => 'application/pdf',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'doc' => 'application/msword',
    'odt' => 'application/vnd.oasis.opendocument.text',
    'rtf' => 'application/rtf',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'xls' => 'application/vnd.ms-excel',
    'html' => 'text/html'
  }.freeze
  EXTENSION_KINDS = {
    'pdf' => 'pdf',
    'docx' => 'docx',
    'doc' => 'doc',
    'odt' => 'odt',
    'rtf' => 'rtf',
    'xlsx' => 'xlsx',
    'xls' => 'xls',
    'html' => 'html',
    'htm' => 'html',
    'xhtml' => 'html'
  }.freeze
  ACCEPTED_DETECTED_TYPES = {
    'pdf' => %w[application/pdf],
    'docx' => %w[application/vnd.openxmlformats-officedocument.wordprocessingml.document application/zip],
    'doc' => %w[application/msword application/x-ole-storage],
    'odt' => %w[application/vnd.oasis.opendocument.text application/zip],
    'rtf' => %w[application/rtf text/rtf application/x-rtf text/plain],
    'xlsx' => %w[application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/zip],
    'xls' => %w[application/vnd.ms-excel application/x-ole-storage],
    'html' => %w[text/html application/xhtml+xml text/plain]
  }.freeze
  ZIP_SIGNATURE = "PK\x03\x04".b.freeze
  OLE_SIGNATURE = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze

  Result = Data.define(:source_kind, :filename, :content_type, :byte_size, :content_hash, :metadata)

  class Error < StandardError; end

  def self.call(io:, filename:, declared_content_type: nil)
    new(io: io, filename: filename, declared_content_type: declared_content_type).call
  end

  def initialize(io:, filename:, declared_content_type: nil)
    @io = io
    @filename = File.basename(filename.to_s.strip)
    @declared_content_type = declared_content_type.to_s.downcase
  end

  def call
    validate_io!
    source_kind = source_kind!
    byte_size = File.size(@io.path)
    raise Error, 'Knowledge file is empty' unless byte_size.positive?
    raise Error, "Knowledge file exceeds #{MAX_FILE_SIZE / 1.megabyte} MB" if byte_size > MAX_FILE_SIZE

    detected_type = Marcel::MimeType.for(Pathname.new(@io.path), name: @filename).to_s
    validate_content_type!(source_kind, detected_type)
    validate_signature!(source_kind)

    Result.new(
      source_kind: source_kind,
      filename: @filename,
      content_type: CONTENT_TYPES.fetch(source_kind),
      byte_size: byte_size,
      content_hash: Digest::SHA256.file(@io.path).hexdigest,
      metadata: { 'original_extension' => File.extname(@filename).downcase }.freeze
    )
  ensure
    @io.rewind if @io.respond_to?(:rewind)
  end

  private

  def validate_io!
    raise Error, 'Knowledge file is missing' unless @io.respond_to?(:path) && File.file?(@io.path)
    raise Error, 'Knowledge filename is missing' if @filename.blank?
    raise Error, 'Knowledge filename is too long' if @filename.length > MAX_FILENAME_LENGTH
    raise Error, 'Knowledge filename is invalid' if @filename.match?(/[[:cntrl:]]/)
  end

  def source_kind!
    extension = File.extname(@filename).downcase.delete_prefix('.')
    source_kind = EXTENSION_KINDS[extension]
    return source_kind if ChatRing::KnowledgeFileSource::SOURCE_KINDS.include?(source_kind)

    raise Error, 'Supported files: PDF, DOCX, DOC, ODT, RTF, XLSX, XLS, HTML, HTM, and XHTML'
  end

  def validate_content_type!(source_kind, detected_type)
    accepted = ACCEPTED_DETECTED_TYPES.fetch(source_kind)
    raise Error, "File content does not match .#{File.extname(@filename).delete_prefix('.')}" unless accepted.include?(detected_type)

    return if @declared_content_type.blank? || @declared_content_type == 'application/octet-stream' ||
              accepted.include?(@declared_content_type)

    raise Error, "Uploaded content type does not match .#{File.extname(@filename).delete_prefix('.')}"
  end

  def validate_signature!(source_kind)
    prefix = File.binread(@io.path, 4096)
    valid = case source_kind
            when 'pdf' then prefix.start_with?('%PDF-')
            when 'docx', 'odt', 'xlsx' then valid_zip_container?(source_kind, prefix)
            when 'doc', 'xls' then prefix.start_with?(OLE_SIGNATURE)
            when 'rtf' then prefix.lstrip.start_with?('{\\rtf')
            when 'html' then prefix.match?(/\A\s*(?:<!doctype\s+html\b|<html\b|<\?xml\b)/i)
            end
    extension = File.extname(@filename).downcase
    raise Error, "File content does not match #{extension}" unless valid
  end

  def valid_zip_container?(source_kind, prefix)
    return false unless prefix.start_with?(ZIP_SIGNATURE)

    archive = File.binread(@io.path)
    required_entries = {
      'docx' => ['[Content_Types].xml', 'word/document.xml'],
      'xlsx' => ['[Content_Types].xml', 'xl/workbook.xml'],
      'odt' => ['mimetype', 'content.xml']
    }.fetch(source_kind)
    required_entries.all? { |entry| archive.include?(entry.b) }
  end
end
