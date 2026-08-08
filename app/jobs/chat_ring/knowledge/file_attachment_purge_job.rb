class ChatRing::Knowledge::FileAttachmentPurgeJob < ApplicationJob
  queue_as :low

  def perform(file_source_id, blob_id)
    source = ChatRing::KnowledgeFileSource.find_by(id: file_source_id)
    return if source.blank?

    blob = source.with_lock do
      next if source.status != 'deleted' || source.materials.active.exists?
      next unless source.file.attached? && source.file.blob_id == blob_id

      attachment = source.file.attachment
      captured_blob = attachment.blob
      attachment.destroy!
      captured_blob
    end
    blob&.purge
  end
end
