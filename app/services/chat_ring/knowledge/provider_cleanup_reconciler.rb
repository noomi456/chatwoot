class ChatRing::Knowledge::ProviderCleanupReconciler
  LOST_JOB_AFTER = 30.minutes

  def self.call(now: Time.current)
    create_missing_records!
    recover_expired_leases!(now)
    enqueue_due_records!(now)
  end

  def self.report(now: Time.current)
    overdue_evaluation_failures = ChatRing::KnowledgeVersion.where(status: 'ready', evaluation_status: 'failed')
    overdue_evaluation_failures = overdue_evaluation_failures.where(
      'evaluated_at <= ?', now - ChatRing::Knowledge::AbandonmentService::AUTOMATIC_GRACE
    )
    expired_leases = ChatRing::KnowledgeProviderCleanup.where(status: 'retrying')
                                                       .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
    {
      overdue_evaluation_failed_versions: overdue_evaluation_failures.count,
      terminal_versions_without_cleanup: cleanup_candidates.count do |version|
        !ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)
      end,
      expired_cleanup_leases: expired_leases.count,
      overdue_pending_cleanups: overdue_pending_scope(now).count,
      exhausted_cleanup_failures: ChatRing::KnowledgeProviderCleanup.where(status: 'failed').count
    }
  end

  def self.overdue_pending_scope(now)
    ChatRing::KnowledgeProviderCleanup.where(status: 'pending')
                                      .where('next_attempt_at <= ?', now)
                                      .where(
                                        'last_enqueued_at IS NULL OR last_enqueued_at <= ?',
                                        now - LOST_JOB_AFTER
                                      )
  end
  private_class_method :overdue_pending_scope

  def self.create_missing_records!
    cleanup_candidates.find_each do |version|
      next if ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)

      ChatRing::Knowledge::ProviderCleanupScheduler.schedule!(version)
    rescue ArgumentError => e
      Rails.logger.error("ChatRing knowledge cleanup record missing version=#{version.id} error=#{e.message}")
    end
  end
  private_class_method :create_missing_records!

  def self.cleanup_candidates
    ChatRing::KnowledgeVersion.where(status: ChatRing::Knowledge::ProviderCleanupScheduler::CLEANABLE_VERSION_STATUSES)
                              .joins(:documents)
                              .where.not(chat_ring_knowledge_documents: { provider_source_id: [nil, ''] })
                              .where.missing(:provider_cleanup)
                              .distinct
  end
  private_class_method :cleanup_candidates

  def self.recover_expired_leases!(now)
    ChatRing::KnowledgeProviderCleanup.where(status: 'retrying')
                                      .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now)
                                      .find_each do |cleanup|
      cleanup.with_lock do
        cleanup.reload
        next unless cleanup.status == 'retrying' &&
                    (cleanup.lease_expires_at.nil? || cleanup.lease_expires_at <= now)

        cleanup.update!(
          status: 'pending',
          next_attempt_at: now,
          last_enqueued_at: nil,
          lease_token: nil,
          lease_expires_at: nil,
          last_error: 'expired cleanup lease recovered'
        )
      end
    end
  end
  private_class_method :recover_expired_leases!

  def self.enqueue_due_records!(now)
    due = ChatRing::KnowledgeProviderCleanup.where(status: 'pending').where('next_attempt_at <= ?', now)
    due.where('last_enqueued_at IS NULL OR last_enqueued_at <= ?', now - LOST_JOB_AFTER).find_each do |cleanup|
      version = cleanup.knowledge_version
      if version.present? && ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)
        ChatRing::Knowledge::ProviderCleanupScheduler.schedule_eligible!(account: version.account, inbox: version.inbox)
        next
      end

      ChatRing::Knowledge::ProviderCleanupScheduler.enqueue_cleanup!(cleanup, now: now)
    end
  end
  private_class_method :enqueue_due_records!
end
