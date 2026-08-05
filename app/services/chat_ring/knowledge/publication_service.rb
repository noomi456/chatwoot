class ChatRing::Knowledge::PublicationService
  class Error < StandardError; end

  def self.publish!(version) # rubocop:disable Metrics/MethodLength
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(version.inbox_id)
      version.lock!
      raise Error, "Knowledge version #{version.id} is not eligible for publication" unless %w[ready retired published].include?(version.status)

      publication = ChatRing::KnowledgePublication.find_or_initialize_by(
        account_id: version.account_id,
        inbox_id: version.inbox_id
      )
      unless publication.persisted? && publication.knowledge_version_id == version.id
        previous = publication.knowledge_version if publication.persisted?
        previous&.update!(status: 'retired') if previous&.status == 'published'
        version.update!(status: 'published', published_at: Time.current)
        publication.update!(
          knowledge_version: version,
          previous_knowledge_version: previous,
          published_at: Time.current
        )
      end
      publication
    end
  end

  def self.rollback!(account:, inbox:)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by!(account: account, inbox: inbox)
      previous = publication.previous_knowledge_version
      raise Error, 'No previous knowledge version is available for rollback' if previous.blank?

      current = publication.knowledge_version
      current.update!(status: 'retired')
      previous.update!(status: 'published', published_at: Time.current)
      publication.update!(
        knowledge_version: previous,
        previous_knowledge_version: current,
        published_at: Time.current
      )
      publication
    end
  end
end
