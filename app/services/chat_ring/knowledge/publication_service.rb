class ChatRing::Knowledge::PublicationService
  class Error < StandardError; end

  def self.publish!(version, validator: ChatRing::Knowledge::ProviderValidator) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    validator.validate!(version)
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
        record_event!(publication, from: previous, to: version, action: 'publish')
      end
      publication
    end
  end

  def self.rollback!(account:, inbox:, validator: ChatRing::Knowledge::ProviderValidator) # rubocop:disable Metrics/MethodLength
    publication = ChatRing::KnowledgePublication.find_by!(account: account, inbox: inbox)
    target = publication.previous_knowledge_version
    raise Error, 'No previous knowledge version is available for rollback' if target.blank?

    validator.validate!(target)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by!(account: account, inbox: inbox)
      previous = publication.previous_knowledge_version
      raise Error, 'No previous knowledge version is available for rollback' if previous.blank?
      raise Error, 'Rollback target changed during validation; retry the operation' unless previous.id == target.id

      current = publication.knowledge_version
      current.update!(status: 'retired')
      previous.update!(status: 'published', published_at: Time.current)
      publication.update!(
        knowledge_version: previous,
        previous_knowledge_version: nil,
        published_at: Time.current
      )
      record_event!(publication, from: current, to: previous, action: 'rollback')
      publication
    end
  end

  def self.record_event!(publication, from:, to:, action:)
    ChatRing::KnowledgePublicationEvent.create!(
      account: publication.account,
      inbox: publication.inbox,
      from_knowledge_version: from,
      to_knowledge_version: to,
      action: action,
      metadata: { 'publication_id' => publication.id }
    )
  end
  private_class_method :record_event!
end
