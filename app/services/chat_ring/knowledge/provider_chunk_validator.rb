require 'digest'

class ChatRing::Knowledge::ProviderChunkValidator
  class Error < StandardError; end

  def self.validate!(documents:, chunks:, error_class: Error)
    new(documents: documents, chunks: chunks, error_class: error_class).validate!
  end

  def initialize(documents:, chunks:, error_class:)
    @documents = documents
    @chunks = chunks
    @error_class = error_class
  end

  def validate!
    failure!('DocsGPT source has no chunks') if @chunks.empty?

    references = @chunks.map { |chunk| source_reference(chunk) }.uniq
    matches = match_references!(references)
    unexpected = references - matches.values
    failure!("DocsGPT contains #{unexpected.length} source reference(s) outside the knowledge-index manifest") if unexpected.any?

    matches.each { |document, reference| validate_document_chunks!(document, reference) }
    matches
  end

  private

  def match_references!(references)
    @documents.to_h do |document|
      candidates = references.select { |reference| matches_document?(document, reference) }
      failure!("DocsGPT chunks do not identify document #{document.id}") unless candidates.one?

      [document, candidates.first]
    end
  end

  def validate_document_chunks!(document, reference)
    chunks = @chunks.select { |chunk| source_reference(chunk) == reference }
    expected_document_id = Digest::SHA256.hexdigest(reference)
    identities = chunks.map { |chunk| chunk_identity!(document, chunk, expected_document_id) }
    validate_identities!(document, identities)
    validate_heading_coverage!(document, chunks)
  end

  def chunk_identity!(document, chunk, expected_document_id)
    values = metadata(chunk)
    document_id = required_digest(values['chatring_document_id'], 'document identity')
    failure!("DocsGPT chunk document identity does not match document #{document.id}") unless document_id == expected_document_id

    index = Integer(values.fetch('chatring_chunk_index'))
    failure!("DocsGPT chunk index is negative for document #{document.id}") if index.negative?
    content_hash = required_digest(values['chatring_content_hash'], 'content hash')
    failure!("DocsGPT chunk content hash does not match document #{document.id}") unless valid_content_hash?(chunk, content_hash)
    validate_heading_path!(document, values)
    [document_id, index, content_hash]
  rescue KeyError, ArgumentError, TypeError
    failure!("DocsGPT chunk metadata is incomplete for document #{document.id}")
  end

  def valid_content_hash?(chunk, content_hash)
    Digest::SHA256.hexdigest(chunk['text'].to_s) == content_hash
  end

  def validate_identities!(document, identities)
    failure!("DocsGPT contains duplicate chunk identities for document #{document.id}") unless identities.uniq.length == identities.length

    indexes = identities.pluck(1).sort
    failure!("DocsGPT chunk indexes are not contiguous for document #{document.id}") unless indexes == (0...indexes.length).to_a
  end

  def validate_heading_coverage!(document, chunks)
    return if heading_paths(document).empty?
    return if chunks.any? { |chunk| metadata(chunk)['chatring_heading_path'].to_s.present? }

    failure!("DocsGPT lost heading paths for headed document #{document.id}")
  end

  def matches_document?(document, reference)
    return reference == document.provider_source_reference if document.provider_source_reference.present?

    File.basename(reference) == document.provider_file_name
  end

  def validate_heading_path!(document, metadata)
    failure!("DocsGPT chunk heading-path metadata is missing for document #{document.id}") unless metadata.key?('chatring_heading_path')

    path = metadata['chatring_heading_path'].to_s
    return if path.blank? || heading_paths(document).include?(path)

    failure!("DocsGPT chunk heading path is outside document #{document.id}")
  end

  def heading_paths(document)
    Array(document.metadata['headings']).filter_map do |heading|
      heading.to_h.stringify_keys['path'].to_s.presence
    end.to_set
  end

  def source_reference(chunk)
    reference = metadata(chunk)['source'].to_s.presence
    failure!('DocsGPT contains chunks without a source reference') if reference.blank?

    reference
  end

  def metadata(chunk)
    values = chunk['metadata']
    failure!('DocsGPT chunk metadata must be an object') unless values.is_a?(Hash)

    values
  end

  def required_digest(value, field)
    digest = value.to_s
    failure!("DocsGPT chunk #{field} is invalid") unless digest.match?(/\A[0-9a-f]{64}\z/)

    digest
  end

  def failure!(message)
    raise @error_class, message
  end
end
