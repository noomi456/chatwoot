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
      cleanup.update!(
        status: 'cancelled',
        last_error: 'knowledge version is retained by a publication pointer'
      )
    end
  end
  private_class_method :cancel_protected!

  def self.schedule!(version)
    source_ids = version.documents.distinct.pluck(:provider_source_id).compact_blank
    return if source_ids.empty?
    raise ArgumentError, 'Cleanup requires exactly one provider source' unless source_ids.one?

    cleanup = ChatRing::KnowledgeProviderCleanup.find_or_initialize_by(knowledge_version: version)
    if cleanup.new_record? || %w[cancelled failed].include?(cleanup.status)
      cleanup.assign_attributes(
        provider_source_id: source_ids.first,
        binding_digest: version.evaluation_binding_digest,
        status: 'pending',
        attempts: 0,
        eligible_at: [version.updated_at + RETENTION, Time.current].max,
        cleaned_at: nil,
        last_error: nil
      )
    end
    cleanup.save!
    ChatRing::Knowledge::ProviderCleanupJob.set(wait_until: cleanup.eligible_at).perform_later(cleanup.id)
    cleanup
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
