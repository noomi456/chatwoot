require 'securerandom'

class ChatRing::Knowledge::ProviderCleanupJob < ApplicationJob
  queue_as :low

  MAX_ATTEMPTS = 10
  LEASE_TTL = 5.minutes
  RETRY_DELAYS = [1.minute, 5.minutes, 15.minutes, 30.minutes, 1.hour, 2.hours, 4.hours, 8.hours, 12.hours].freeze

  Claim = Data.define(:cleanup_id, :lease_token, :account_id, :knowledge_version_id, :binding_digest, :provider_source_id)

  def perform(cleanup_id)
    claim = claim_cleanup(cleanup_id)
    return if claim.blank?

    docs_gpt_client.delete_source(
      account_id: claim.account_id,
      knowledge_version_id: claim.knowledge_version_id,
      binding_digest: claim.binding_digest,
      source_id: claim.provider_source_id
    )
    complete_cleanup(claim)
  rescue ChatRing::Knowledge::DocsGptClient::Error => e
    retry_cleanup(claim, e) if claim.present?
  end

  private

  def claim_cleanup(cleanup_id, now: Time.current)
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: cleanup_id)
    return if cleanup.blank?

    cleanup.with_lock do
      cleanup.reload
      next if %w[succeeded cancelled failed].include?(cleanup.status)
      next if cancel_if_protected!(cleanup)
      next unless due_for_claim?(cleanup, now)

      acquire_claim!(cleanup, now)
    end
  end

  def cancel_if_protected!(cleanup)
    version = cleanup.knowledge_version
    return false if version.blank? || !ChatRing::Knowledge::ProviderCleanupScheduler.protected?(version)

    cleanup.update!(
      status: 'cancelled',
      lease_token: nil,
      lease_expires_at: nil,
      last_error: 'knowledge version is retained by a publication pointer'
    )
    true
  end

  def due_for_claim?(cleanup, now)
    active_lease = cleanup.status == 'retrying' && cleanup.lease_expires_at.present? && cleanup.lease_expires_at > now
    !active_lease && [cleanup.eligible_at, cleanup.next_attempt_at].compact.max <= now
  end

  def acquire_claim!(cleanup, now)
    token = SecureRandom.uuid
    cleanup.update!(
      status: 'retrying',
      attempts: cleanup.attempts + 1,
      lease_token: token,
      lease_expires_at: now + LEASE_TTL,
      last_error: nil
    )
    Claim.new(
      cleanup_id: cleanup.id,
      lease_token: token,
      account_id: cleanup.account_id,
      knowledge_version_id: cleanup.knowledge_version_id,
      binding_digest: cleanup.binding_digest,
      provider_source_id: cleanup.provider_source_id
    )
  end

  def complete_cleanup(claim)
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: claim.cleanup_id)
    cleanup&.with_lock do
      next unless cleanup.lease_token == claim.lease_token

      cleanup.update!(
        status: 'succeeded',
        cleaned_at: Time.current,
        next_attempt_at: Time.current,
        lease_token: nil,
        lease_expires_at: nil,
        last_error: nil
      )
    end
  end

  def retry_cleanup(claim, error, now: Time.current)
    cleanup = ChatRing::KnowledgeProviderCleanup.find_by(id: claim.cleanup_id)
    should_enqueue = false
    cleanup&.with_lock do
      next unless cleanup.lease_token == claim.lease_token

      if cleanup.attempts >= MAX_ATTEMPTS
        mark_failed!(cleanup, error)
      else
        schedule_retry!(cleanup, error, now)
        should_enqueue = true
      end
    end
    ChatRing::Knowledge::ProviderCleanupScheduler.enqueue_cleanup!(cleanup, now: now) if should_enqueue
  end

  def mark_failed!(cleanup, error)
    cleanup.update!(
      status: 'failed',
      lease_token: nil,
      lease_expires_at: nil,
      last_error: error.message.to_s.truncate(1000)
    )
  end

  def schedule_retry!(cleanup, error, now)
    cleanup.update!(
      status: 'pending',
      next_attempt_at: now + retry_delay(cleanup.attempts),
      last_enqueued_at: nil,
      lease_token: nil,
      lease_expires_at: nil,
      last_error: error.message.to_s.truncate(1000)
    )
  end

  def retry_delay(attempts)
    RETRY_DELAYS.fetch(attempts - 1, RETRY_DELAYS.last)
  end

  def docs_gpt_client
    ChatRing::Knowledge::DocsGptClient.new(
      base_url: ENV.fetch('DOCSGPT_BASE_URL'),
      jwt_secret: ENV.fetch('DOCSGPT_JWT_SECRET'),
      internal_key: ENV.fetch('DOCSGPT_INTERNAL_KEY'),
      service_secret: ENV.fetch('DOCSGPT_SERVICE_SECRET')
    )
  end
end
