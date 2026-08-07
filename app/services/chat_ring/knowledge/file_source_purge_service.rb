class ChatRing::Knowledge::FileSourcePurgeService
  class Error < StandardError; end

  def self.call(source)
    source.with_lock do
      raise Error, 'Disable the file source before purging it' unless source.status == 'disabled'

      publication = ChatRing::KnowledgePublication.find_by(account_id: source.account_id, inbox_id: source.inbox_id)
      if publication && source.knowledge_documents.exists?(knowledge_version_id: publication.knowledge_version_id)
        raise Error, 'Publish a knowledge version without this file before purging it'
      end

      source.file.purge if source.file.attached?
      source.destroy!
    end
  end
end
