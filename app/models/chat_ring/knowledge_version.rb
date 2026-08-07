require 'digest'

class ChatRing::KnowledgeVersion < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_versions'

  STATUSES = %w[pending crawling ingesting ready published retired failed abandoned].freeze
  EVALUATION_STATUSES = %w[pending passed failed].freeze
  IMMUTABLE_BUILD_STATUSES = %w[ready published retired abandoned].freeze
  IMMUTABLE_BUILD_ATTRIBUTES = %w[
    account_id inbox_id provider provider_release root_url mapped_manifest manifest_digest crawl_errors config_snapshot
  ].freeze

  belongs_to :account
  belongs_to :inbox
  has_many :documents,
           class_name: 'ChatRing::KnowledgeDocument',
           inverse_of: :knowledge_version,
           dependent: :destroy
  has_many :publication_events,
           class_name: 'ChatRing::KnowledgePublicationEvent',
           foreign_key: :to_knowledge_version_id,
           inverse_of: :to_knowledge_version,
           dependent: :restrict_with_exception
  has_one :provider_cleanup,
          class_name: 'ChatRing::KnowledgeProviderCleanup',
          inverse_of: :knowledge_version,
          dependent: nil

  encrypts :provider_agent_api_key

  validates :status, inclusion: { in: STATUSES }
  validates :evaluation_status, inclusion: { in: EVALUATION_STATUSES }
  validates :provider, :provider_release, :root_url, presence: true
  validate :inbox_belongs_to_account
  validate :completed_build_snapshot_is_immutable, on: :update
  validate :abandoned_status_has_audit_fields
  validate :abandoned_version_is_terminal, on: :update
  validate :abandonment_audit_is_immutable, on: :update

  scope :published, -> { where(status: 'published') }

  def fail!(code:, message:)
    update!(status: 'failed', failure_code: code.to_s, failure_message: message.to_s.truncate(1000))
  end

  def evaluation_binding_digest
    document_hashes = documents.order(:id).pluck(:content_hash)
    Digest::SHA256.hexdigest(
      [manifest_digest, provider_release, config_snapshot, document_hashes].to_json
    )
  end

  def evaluation_passed_for_current_content?
    evaluation_status == 'passed' &&
      evaluated_at.present? &&
      evaluation_report['binding_digest'] == evaluation_binding_digest
  end

  private

  def inbox_belongs_to_account
    return if inbox.blank? || account.blank? || inbox.account_id == account_id

    errors.add(:inbox, 'must belong to the selected account')
  end

  def abandoned_status_has_audit_fields
    return unless status == 'abandoned'
    return if abandoned_at.present? && abandon_reason.present?

    errors.add(:base, 'abandoned knowledge version requires timestamp and reason')
  end

  def abandoned_version_is_terminal
    return unless attribute_in_database('status') == 'abandoned' && will_save_change_to_status?

    errors.add(:status, 'cannot change after abandonment')
  end

  def abandonment_audit_is_immutable
    return unless attribute_in_database('status') == 'abandoned'
    return unless will_save_change_to_abandoned_at? || will_save_change_to_abandon_reason?

    errors.add(:base, 'abandonment audit fields are immutable')
  end

  def completed_build_snapshot_is_immutable
    return unless IMMUTABLE_BUILD_STATUSES.include?(attribute_in_database('status'))
    return unless IMMUTABLE_BUILD_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'completed knowledge-version build snapshot is immutable')
  end
end
