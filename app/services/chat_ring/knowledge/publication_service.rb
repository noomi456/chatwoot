class ChatRing::Knowledge::PublicationService
  class Error < StandardError; end

  def self.publish!(version, validator: ChatRing::Knowledge::ProviderValidator) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    ensure_publishable!(version)
    validator.validate!(version)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(version.inbox_id)
      version.lock!
      ensure_publishable!(version)

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

    ensure_evaluated!(target, message: 'Rollback target has not passed the current retrieval evaluation')
    validator.validate!(target)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by!(account: account, inbox: inbox)
      previous = publication.previous_knowledge_version
      raise Error, 'No previous knowledge version is available for rollback' if previous.blank?
      raise Error, 'Rollback target changed during validation; retry the operation' unless previous.id == target.id
      ensure_evaluated!(previous, message: 'Rollback target has not passed the current retrieval evaluation')

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

  def self.ensure_publishable!(version)
    unless %w[ready retired published].include?(version.status)
      raise Error, "Knowledge version #{version.id} is not eligible for publication"
    end

    ensure_evaluated!(version, message: "Knowledge version #{version.id} has not passed the current retrieval evaluation")
  end
  private_class_method :ensure_publishable!

  def self.ensure_evaluated!(version, message:)
    raise Error, message unless version.evaluation_passed_for_current_content?
  end
  private_class_method :ensure_evaluated!
end
