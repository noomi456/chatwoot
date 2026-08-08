class ChatRing::Knowledge::MaterialService
  class Error < StandardError; end

  def self.delete!(material)
    file_source = nil
    blob_id = nil
    ChatRing::KnowledgeMaterial.transaction do
      material.knowledge_base.lock!
      file_source = material.file_source
      file_source&.lock!
      material.lock!
      return material unless material.active?

      material.update!(
        status: 'failed',
        markdown: nil,
        content_hash: nil,
        metadata: {},
        risk_flags: [],
        extracted_at: nil,
        deleted_at: Time.current
      )
      if file_source
        blob_id = file_source.file.blob_id if file_source.file.attached?
        file_source.update!(
          status: 'deleted',
          markdown: nil,
          content_hash: nil,
          metadata: {},
          parsed_at: nil,
          disabled_at: Time.current
        )
      end
    end

    # Retrieval checks the catalog tombstone immediately. Provider cleanup and
    # replacement happen after the user-visible delete has succeeded.
    ChatRing::Knowledge::FileAttachmentPurgeJob.perform_later(file_source.id, blob_id) if file_source && blob_id
    ChatRing::Knowledge::IndexBuilder.enqueue!(material.knowledge_base)
    material
  end
end
