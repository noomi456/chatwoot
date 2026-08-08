class ChatRing::Knowledge::FileAttachmentPurgeJob < ApplicationJob
  queue_as :low

  def perform(file_source_id, blob_id)
    source = ChatRing::KnowledgeFileSource.find_by(id: file_source_id)
    return if source.blank? || source.status != 'deleted' || source.materials.active.exists?
    return unless source.file.attached? && source.file.blob_id == blob_id

    source.file.purge
  end
end
