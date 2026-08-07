class ChatRing::KnowledgeProviderCleanup < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_provider_cleanups'

  STATUSES = %w[pending retrying succeeded cancelled failed].freeze

  belongs_to :knowledge_version,
             class_name: 'ChatRing::KnowledgeVersion',
             inverse_of: :provider_cleanup,
             optional: true

  before_validation :default_next_attempt_at

  validates :account_id, :inbox_id, :knowledge_version_id, :provider_source_id, :binding_digest,
            :eligible_at, :next_attempt_at, presence: true
  validates :knowledge_version_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :manual_retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :binding_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :lease_fields_are_paired

  private

  def default_next_attempt_at
    self.next_attempt_at ||= eligible_at
  end

  def lease_fields_are_paired
    fields_paired = lease_token.present? == lease_expires_at.present?
    status_matches = (status == 'retrying') == lease_token.present?
    return if fields_paired && status_matches

    errors.add(:base, 'cleanup lease fields must exist only while retrying')
  end
end
