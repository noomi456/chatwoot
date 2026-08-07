class ChatRing::Knowledge::PublicationService
  class Error < StandardError; end

  def self.publish!(version, validator: ChatRing::Knowledge::ProviderValidator, actor: nil)
    ensure_publishable!(version)
    validator.validate!(version)
    publication = publish_transaction(version, actor: actor)
    schedule_cleanup(publication)
    publication
  end

  def self.publish_verified!(version, validator: ChatRing::Knowledge::ProviderValidator, actor: nil)
    ensure_source_managed_publishable!(version)
    validator.validate!(version)
    publication = publish_transaction(version, actor: actor, require_evaluation: false)
    schedule_cleanup(publication)
    publication
  end

  def self.clear!(account:, inbox:)
    current = ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by(account: account, inbox: inbox)
      next unless publication

      version = publication.knowledge_version
      version.update!(status: 'retired') if version.status == 'published'
      publication.destroy!
      version
    end
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(account: account, inbox: inbox) if current
    current
  end

  def self.publish_transaction(version, actor:, require_evaluation: true)
    ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(version.inbox_id)
      version.lock!
      require_evaluation ? ensure_publishable!(version) : ensure_source_managed_publishable!(version)
      ChatRing::Knowledge::ProviderCleanupScheduler.reserve_for_publication!(version)

      publication = ChatRing::KnowledgePublication.find_or_initialize_by(
        account_id: version.account_id,
        inbox_id: version.inbox_id
      )
      activate_publication(publication, version, actor: actor) unless publication.persisted? && publication.knowledge_version_id == version.id
      publication
    end
  end
  private_class_method :publish_transaction

  def self.activate_publication(publication, version, actor:)
    previous = publication.knowledge_version if publication.persisted?
    previous&.update!(status: 'retired') if previous&.status == 'published'
    version.update!(status: 'published', published_at: Time.current)
    publication.update!(
      knowledge_version: version,
      previous_knowledge_version: previous,
      published_at: Time.current
    )
    record_event!(publication, from: previous, to: version, action: 'publish', actor: actor)
  end
  private_class_method :activate_publication

  def self.rollback!(account:, inbox:, validator: ChatRing::Knowledge::ProviderValidator, actor: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    publication = ChatRing::KnowledgePublication.find_by!(account: account, inbox: inbox)
    target = publication.previous_knowledge_version
    raise Error, 'No previous knowledge version is available for rollback' if target.blank?

    validator.validate!(target)
    publication = ChatRing::KnowledgePublication.transaction do
      Inbox.lock.find(inbox.id)
      publication = ChatRing::KnowledgePublication.lock.find_by!(account: account, inbox: inbox)
      previous = publication.previous_knowledge_version
      raise Error, 'No previous knowledge version is available for rollback' if previous.blank?
      raise Error, 'Rollback target changed during validation; retry the operation' unless previous.id == target.id

      ensure_rollback_publishable!(previous)
      ChatRing::Knowledge::ProviderCleanupScheduler.reserve_for_publication!(previous)

      current = publication.knowledge_version
      current.update!(status: 'retired')
      previous.update!(status: 'published', published_at: Time.current)
      publication.update!(
        knowledge_version: previous,
        previous_knowledge_version: nil,
        published_at: Time.current
      )
      record_event!(publication, from: current, to: previous, action: 'rollback', actor: actor)
      publication
    end
    schedule_cleanup(publication)
    publication
  end

  def self.record_event!(publication, from:, to:, action:, actor:)
    ChatRing::KnowledgePublicationEvent.create!(
      account: publication.account,
      inbox: publication.inbox,
      from_knowledge_version: from,
      to_knowledge_version: to,
      action: action,
      metadata: { 'publication_id' => publication.id, 'actor_id' => actor&.id }.compact
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

    ensure_complete_enabled_file_set!(version)
    ensure_evaluated!(version, message: "Knowledge version #{version.id} has not passed the current retrieval evaluation")
  end
  private_class_method :ensure_publishable!

  def self.ensure_source_managed_publishable!(version)
    raise Error, "Knowledge version #{version.id} is not eligible for publication" unless %w[ready retired published].include?(version.status)

    ensure_complete_enabled_file_set!(version)
  end
  private_class_method :ensure_source_managed_publishable!

  def self.ensure_rollback_publishable!(version)
    return if %w[ready retired published].include?(version.status)

    raise Error, "Knowledge version #{version.id} is not eligible for rollback"
  end
  private_class_method :ensure_rollback_publishable!

  def self.ensure_complete_enabled_file_set!(version)
    expected_ids = ChatRing::KnowledgeFileSource.where(account_id: version.account_id, inbox_id: version.inbox_id).available.ready.order(:id).ids
    actual_ids = version.documents.where.not(file_source_id: nil).distinct.order(:file_source_id).pluck(:file_source_id)
    return if actual_ids == expected_ids

    raise Error, 'Knowledge version does not contain the complete enabled file-source set; rebuild it before publishing'
  end
  private_class_method :ensure_complete_enabled_file_set!

  def self.ensure_evaluated!(version, message:)
    raise Error, message unless version.evaluation_passed_for_current_content?
  end
  private_class_method :ensure_evaluated!
end
