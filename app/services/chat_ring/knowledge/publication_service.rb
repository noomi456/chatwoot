class ChatRing::Knowledge::PublicationService
  class Error < StandardError; end

  def self.publish!(version, validator: ChatRing::Knowledge::ProviderValidator)
    ensure_publishable!(version)
    validator.validate!(version)
    publication = publish_transaction(version)
    schedule_cleanup(publication)
    publication
  end

  def self.publish_transaction(version)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(version.inbox_id)
      version.lock!
      ensure_publishable!(version)
      ChatRing::Knowledge::ProviderCleanupScheduler.reserve_for_publication!(version)

      publication = ChatRing::KnowledgePublication.find_or_initialize_by(
        account_id: version.account_id,
        inbox_id: version.inbox_id
      )
      activate_publication(publication, version) unless publication.persisted? && publication.knowledge_version_id == version.id
      publication
    end
  end
  private_class_method :publish_transaction

  def self.activate_publication(publication, version)
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
  private_class_method :activate_publication

  def self.rollback!(account:, inbox:, validator: ChatRing::Knowledge::ProviderValidator) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    publication = ChatRing::KnowledgePublication.find_by!(account: account, inbox: inbox)
    target = publication.previous_knowledge_version
    raise Error, 'No previous knowledge version is available for rollback' if target.blank?

    ensure_evaluated!(target, message: 'Rollback target has not passed the current retrieval evaluation')
    validator.validate!(target)
    publication = ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by!(account: account, inbox: inbox)
      previous = publication.previous_knowledge_version
      raise Error, 'No previous knowledge version is available for rollback' if previous.blank?
      raise Error, 'Rollback target changed during validation; retry the operation' unless previous.id == target.id

      ensure_evaluated!(previous, message: 'Rollback target has not passed the current retrieval evaluation')
      ChatRing::Knowledge::ProviderCleanupScheduler.reserve_for_publication!(previous)

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
    schedule_cleanup(publication)
    publication
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

  def self.schedule_cleanup(publication)
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(
      account: publication.account,
      inbox: publication.inbox
    )
  end
  private_class_method :schedule_cleanup

  def self.ensure_publishable!(version)
    raise Error, "Knowledge version #{version.id} is not eligible for publication" unless %w[ready retired published].include?(version.status)

    ensure_evaluated!(version, message: "Knowledge version #{version.id} has not passed the current retrieval evaluation")
  end
  private_class_method :ensure_publishable!

  def self.ensure_evaluated!(version, message:)
    raise Error, message unless version.evaluation_passed_for_current_content?
  end
  private_class_method :ensure_evaluated!
end
