class ChatRing::Knowledge::ProviderCleanupScheduler
  RETENTION = 1.hour
  CLEANABLE_INDEX_STATUSES = %w[retired failed discarded].freeze

  def self.schedule_eligible!(knowledge_base:)
    active_id = knowledge_base.active_knowledge_index_id
    knowledge_base.knowledge_indexes.where(status: CLEANABLE_INDEX_STATUSES)
                  .where.not(id: active_id)
                  .find_each { |index| schedule!(index) }
  end

  def self.schedule!(index, eligible_at: nil, force: false, enqueue: true)
    source_id = provider_source_id(index)
    return if source_id.blank? || (!force && protected?(index))

    cleanup = ChatRing::KnowledgeProviderCleanup.find_or_initialize_by(knowledge_index_id: index.id)
    return cleanup if cleanup.persisted? && %w[pending retrying succeeded].include?(cleanup.status)

    cleanup.assign_attributes(
      knowledge_base: index.knowledge_base,
      account_id: index.account_id,
      provider_source_id: source_id,
      binding_digest: index.provider_binding_digest,
      status: 'pending',
      attempts: 0,
      eligible_at: eligible_at || [index.updated_at + RETENTION, Time.current].max,
      cleaned_at: nil,
      last_error: nil
    )
    cleanup.save!
    enqueue_cleanup!(cleanup) if enqueue
    cleanup
  end

  def self.enqueue_cleanup!(cleanup)
    return false unless cleanup.status == 'pending'

    ChatRing::Knowledge::ProviderCleanupJob.set(wait_until: cleanup.eligible_at).perform_later(cleanup.id)
    true
  end

  def self.retry_failed!(cleanup)
    raise ArgumentError, 'Only a failed provider cleanup can be retried' unless cleanup.status == 'failed'
    raise ArgumentError, 'The active provider index cannot be deleted' if protected?(cleanup.knowledge_index)

    cleanup.update!(status: 'pending', attempts: 0, eligible_at: Time.current, cleaned_at: nil, last_error: nil)
    enqueue_cleanup!(cleanup)
    cleanup
  end

  def self.prepare_account_deletion!(account_id:)
    workspace = ChatRing::Workspace.find_by(chatwoot_account_id: account_id)
    return [] unless workspace&.knowledge_base

    workspace.knowledge_base.knowledge_indexes.filter_map do |index|
      schedule!(index, eligible_at: Time.current, force: true, enqueue: false)
    end
  end

  def self.enqueue!(cleanup_ids)
    Array(cleanup_ids).each do |cleanup_id|
      cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: cleanup_id)
      enqueue_cleanup!(cleanup) if cleanup
    end
  end

  def self.protected?(index)
    index.present? && index.knowledge_base.active_knowledge_index_id == index.id
  end

  def self.provider_source_id(index)
    source_ids = index.documents.distinct.pluck(:provider_source_id).compact_blank
    return if source_ids.empty?
    raise ArgumentError, 'Cleanup requires exactly one provider source' unless source_ids.one?

    source_ids.first
  end
  private_class_method :provider_source_id
end
