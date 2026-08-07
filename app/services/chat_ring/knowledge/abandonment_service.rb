class ChatRing::Knowledge::AbandonmentService
  AUTOMATIC_GRACE = 7.days

  class Error < StandardError; end

  def self.abandon!(version, reason:, now: Time.current, cleanup_eligible_at: nil, evaluation_failed_before: nil)
    reason = reason.to_s.squish
    raise Error, 'Abandonment reason is required' if reason.blank?

    version.with_lock do
      version.reload
      raise Error, "Knowledge version #{version.id} is not ready" unless version.status == 'ready'

      ensure_expected_evaluation_failure!(version, evaluation_failed_before) if evaluation_failed_before.present?
      if ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)
        raise Error, "Knowledge version #{version.id} is retained by a publication pointer"
      end

      version.update!(status: 'abandoned', abandoned_at: now, abandon_reason: reason.truncate(1000))
    end
    ChatRing::Knowledge::ProviderCleanupScheduler.schedule!(version, eligible_at: cleanup_eligible_at)
    version
  end

  def self.abandon_overdue_evaluation_failures!(now: Time.current)
    cutoff = now - AUTOMATIC_GRACE
    candidates = ChatRing::KnowledgeVersion.where(status: 'ready', evaluation_status: 'failed')
                                           .where('evaluated_at <= ?', cutoff)
    candidates.filter_map do |version|
      abandon!(
        version,
        reason: 'evaluation_failed_grace_elapsed',
        now: now,
        cleanup_eligible_at: now,
        evaluation_failed_before: cutoff
      )
    rescue Error, ArgumentError => e
      Rails.logger.info("ChatRing knowledge abandonment skipped version=#{version.id} reason=#{e.message}")
      nil
    end
  end

  def self.ensure_expected_evaluation_failure!(version, cutoff)
    return if version.evaluation_status == 'failed' && version.evaluated_at.present? && version.evaluated_at <= cutoff

    raise Error, "Knowledge version #{version.id} evaluation failure is no longer eligible for automatic abandonment"
  end
  private_class_method :ensure_expected_evaluation_failure!
end
