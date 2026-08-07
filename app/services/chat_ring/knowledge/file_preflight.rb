require 'digest'
require 'marcel'
require 'pathname'

class ChatRing::Knowledge::FilePreflight
  MAX_FILE_SIZE = ChatRing::KnowledgeFileSource::MAX_FILE_SIZE
  MAX_FILENAME_LENGTH = 255
  CONTENT_TYPES = {
    'pdf' => 'application/pdf',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  }.freeze

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
      metadata: {}.freeze
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
    return extension if ChatRing::KnowledgeFileSource::SOURCE_KINDS.include?(extension)

    raise Error, 'Only PDF and DOCX files are supported'
  end

  def validate_content_type!(source_kind, detected_type)
    expected = CONTENT_TYPES.fetch(source_kind)
    accepted_detected = source_kind == 'docx' ? [expected, 'application/zip'] : [expected]
    raise Error, "File content does not match .#{source_kind}" unless accepted_detected.include?(detected_type)

    return if @declared_content_type.blank? || @declared_content_type == 'application/octet-stream' ||
              accepted_detected.include?(@declared_content_type)

    raise Error, "Uploaded content type does not match .#{source_kind}"
  end

  def validate_signature!(source_kind)
    signature = File.binread(@io.path, 8)
    valid = source_kind == 'pdf' ? signature.start_with?('%PDF-') : signature.start_with?("PK\x03\x04".b)
    raise Error, "File content does not match .#{source_kind}" unless valid
  end
end
