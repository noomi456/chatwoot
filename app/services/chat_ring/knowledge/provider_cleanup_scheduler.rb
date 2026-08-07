class ChatRing::Knowledge::ProviderCleanupScheduler
  RETENTION = 7.days

  def self.schedule_eligible!(account:, inbox:)
    publications = ChatRing::KnowledgePublication.where(account: account, inbox: inbox)
    protected_ids = publications.pluck(:knowledge_version_id, :previous_knowledge_version_id).flatten.compact
    cancel_protected!(protected_ids)
    ChatRing::KnowledgeVersion.where(account: account, inbox: inbox, status: %w[retired failed])
                              .where.not(id: protected_ids)
                              .find_each { |version| schedule!(version) }
  end

  def self.cancel_protected!(protected_ids)
    return if protected_ids.empty?

    ChatRing::KnowledgeProviderCleanup.where(
      knowledge_version_id: protected_ids,
      status: %w[pending retrying]
    ).find_each do |cleanup|
      cleanup.with_lock do
        next unless cleanup.status == 'pending'

        cleanup.update!(status: 'cancelled', last_error: 'knowledge version is retained by a publication pointer')
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
    Array(cleanup_ids).each { |cleanup_id| ChatRing::Knowledge::ProviderCleanupJob.perform_later(cleanup_id) }
  end

  def self.schedule!(version, eligible_at: nil, force: false, enqueue: true)
    source_id = provider_source_id(version)
    return if source_id.blank?

    cleanup = build_cleanup(version, source_id, eligible_at, force)
    enqueue_cleanup(cleanup) if enqueue && cleanup_schedule_changed?(cleanup)
    cleanup
  end

  def self.cleanup_schedule_changed?(cleanup)
    cleanup.present? && (cleanup.previously_new_record? || cleanup.saved_change_to_status? || cleanup.saved_change_to_eligible_at?)
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
    %w[retired failed].include?(version.status) && !protected?(version)
  end
  private_class_method :cleanup_eligible?

  def self.cleanup_assignable?(cleanup, force)
    cleanup.new_record? || force || %w[cancelled failed].include?(cleanup.status)
  end
  private_class_method :cleanup_assignable?

  def self.assign_cleanup(cleanup, version, source_id, eligible_at)
    succeeded = cleanup.status == 'succeeded'
    cleanup.assign_attributes(
      knowledge_version_id: version.id,
      account_id: version.account_id,
      inbox_id: version.inbox_id,
      provider_source_id: source_id,
      binding_digest: version.evaluation_binding_digest,
      status: succeeded ? 'succeeded' : 'pending',
      attempts: succeeded ? cleanup.attempts : 0,
      eligible_at: eligible_at || [version.updated_at + RETENTION, Time.current].max,
      cleaned_at: succeeded ? cleanup.cleaned_at : nil,
      last_error: nil
    )
  end
  private_class_method :assign_cleanup

  def self.enqueue_cleanup(cleanup)
    return if cleanup.blank? || cleanup.status == 'succeeded'

    ChatRing::Knowledge::ProviderCleanupJob.set(wait_until: cleanup.eligible_at).perform_later(cleanup.id)
  end
  private_class_method :enqueue_cleanup

  def self.reserve_for_publication!(version)
    cleanup = version.provider_cleanup
    return if cleanup.blank?

    cleanup.with_lock do
      if %w[pending cancelled].include?(cleanup.status)
        cleanup.update!(status: 'cancelled', last_error: 'knowledge version is retained by a publication pointer')
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
