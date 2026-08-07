class ChatRing::Knowledge::ProviderCleanupScheduler
  RETENTION = 7.days
  CLEANABLE_VERSION_STATUSES = %w[retired failed abandoned].freeze

  def self.schedule_eligible!(account:, inbox:)
    publications = ChatRing::KnowledgePublication.where(account: account, inbox: inbox)
    protected_ids = publications.pluck(:knowledge_version_id, :previous_knowledge_version_id).flatten.compact
    cancel_protected!(protected_ids)
    ChatRing::KnowledgeVersion.where(account: account, inbox: inbox, status: CLEANABLE_VERSION_STATUSES)
                              .where.not(id: protected_ids)
                              .find_each { |version| schedule!(version) }
  end

  def self.cancel_protected!(protected_ids)
    return if protected_ids.empty?

    ChatRing::KnowledgeProviderCleanup.where(knowledge_version_id: protected_ids, status: 'pending').find_each do |cleanup|
      cleanup.with_lock do
        next unless cleanup.status == 'pending'

        cleanup.update!(
          status: 'cancelled',
          lease_token: nil,
          lease_expires_at: nil,
          last_error: 'knowledge version is retained by a publication pointer'
        )
      end
    end
  end
  private_class_method :cancel_protected!

  def self.prepare_scope_deletion!(account_id:, inbox_id: nil)
    versions = ChatRing::KnowledgeVersion.where(account_id: account_id)
    versions = versions.where(inbox_id: inbox_id) if inbox_id.present?
    versions.filter_map { |version| schedule!(version, eligible_at: Time.current, force: true, enqueue: false) }
  end

  def self.enqueue!(cleanup_ids)
    Array(cleanup_ids).each do |cleanup_id|
      cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: cleanup_id)
      enqueue_cleanup!(cleanup) if cleanup.present?
    end
  end

  def self.schedule!(version, eligible_at: nil, force: false, enqueue: true)
    source_id = provider_source_id(version)
    return if source_id.blank?

    cleanup = build_cleanup(version, source_id, eligible_at, force)
    enqueue_cleanup!(cleanup) if enqueue && cleanup_schedule_changed?(cleanup)
    cleanup
  end

  def self.enqueue_cleanup!(cleanup, now: Time.current)
    return false unless cleanup.status == 'pending'

    due_at = [cleanup.eligible_at, cleanup.next_attempt_at].compact.max
    job = ChatRing::Knowledge::ProviderCleanupJob.set(wait_until: due_at).perform_later(cleanup.id)
    return false unless job.successfully_enqueued?

    cleanup.update_column(:last_enqueued_at, now) # rubocop:disable Rails/SkipsModelValidations
    true
  end

  def self.retry_failed!(cleanup, now: Time.current)
    cleanup.with_lock do
      ensure_retryable!(cleanup)

      cleanup.update!(
        status: 'pending',
        attempts: 0,
        manual_retry_count: cleanup.manual_retry_count + 1,
        next_attempt_at: now,
        last_enqueued_at: nil,
        lease_token: nil,
        lease_expires_at: nil,
        cleaned_at: nil,
        last_error: nil
      )
    end
    enqueue_cleanup!(cleanup, now: now)
    cleanup
  end

  def self.ensure_retryable!(cleanup)
    raise ArgumentError, 'Only a failed provider cleanup can be retried' unless cleanup.status == 'failed'

    version = cleanup.knowledge_version
    raise ArgumentError, 'A publication-protected provider cleanup cannot be retried' if version.present? && protected?(version)
  end
  private_class_method :ensure_retryable!

  def self.cleanup_schedule_changed?(cleanup)
    cleanup.present? &&
      (cleanup.previously_new_record? || cleanup.saved_change_to_status? || cleanup.saved_change_to_next_attempt_at?)
  end
  private_class_method :cleanup_schedule_changed?

  def self.build_cleanup(version, source_id, eligible_at, force)
    version.with_lock do
      version.reload
      next unless force || cleanup_eligible?(version)

      cleanup = ChatRing::KnowledgeProviderCleanup.find_or_initialize_by(knowledge_version_id: version.id)
      cleanup.lock! if cleanup.persisted?
      assign_cleanup(cleanup, version, source_id, eligible_at) if cleanup_assignable?(cleanup, force)
      cleanup.save!
      cleanup
    end
  end
  private_class_method :build_cleanup

  def self.provider_source_id(version)
    source_ids = version.documents.distinct.pluck(:provider_source_id).compact_blank
    return if source_ids.empty?
    raise ArgumentError, 'Cleanup requires exactly one provider source' unless source_ids.one?

    source_ids.first
  end
  private_class_method :provider_source_id

  def self.cleanup_eligible?(version)
    CLEANABLE_VERSION_STATUSES.include?(version.status) && !protected?(version)
  end
  private_class_method :cleanup_eligible?

  def self.cleanup_assignable?(cleanup, force)
    cleanup.new_record? || force || cleanup.status == 'cancelled'
  end
  private_class_method :cleanup_assignable?

  def self.assign_cleanup(cleanup, version, source_id, eligible_at)
    succeeded = cleanup.status == 'succeeded'
    first_attempt_at = eligible_at || [version.updated_at + RETENTION, Time.current].max
    cleanup.assign_attributes(
      knowledge_version_id: version.id,
      account_id: version.account_id,
      inbox_id: version.inbox_id,
      provider_source_id: source_id,
      binding_digest: version.evaluation_binding_digest,
      status: succeeded ? 'succeeded' : 'pending',
      attempts: succeeded ? cleanup.attempts : 0,
      eligible_at: first_attempt_at,
      next_attempt_at: first_attempt_at,
      last_enqueued_at: nil,
      lease_token: nil,
      lease_expires_at: nil,
      cleaned_at: succeeded ? cleanup.cleaned_at : nil,
      last_error: nil
    )
  end
  private_class_method :assign_cleanup

  def self.reserve_for_publication!(version)
    cleanup = version.provider_cleanup
    return if cleanup.blank?

    cleanup.with_lock do
      if %w[pending cancelled].include?(cleanup.status)
        cleanup.update!(
          status: 'cancelled',
          lease_token: nil,
          lease_expires_at: nil,
          last_error: 'knowledge version is retained by a publication pointer'
        )
      else
        raise ChatRing::Knowledge::PublicationService::Error,
              "Knowledge version #{version.id} provider cleanup has already started"
      end
    end
  end

  def self.protected?(version)
    publications = ChatRing::KnowledgePublication.where(
      account_id: version.account_id,
      inbox_id: version.inbox_id
    )
    publications.exists?(
      ['knowledge_version_id = :id OR previous_knowledge_version_id = :id', { id: version.id }]
    )
  end
end
