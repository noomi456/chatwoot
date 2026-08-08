require 'digest'

# An immutable DocsGPT index build. This is internal storage plumbing, not a
# customer-visible knowledge version or publication workflow.
class ChatRing::KnowledgeIndex < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_indexes'

  STATUSES = %w[building ready active retired failed discarded].freeze
  IMMUTABLE_STATUSES = %w[ready active retired discarded].freeze
  IMMUTABLE_ATTRIBUTES = %w[
    workspace_id knowledge_base_id provider provider_release mapped_manifest manifest_digest crawl_errors config_snapshot
  ].freeze

  belongs_to :workspace, class_name: 'ChatRing::Workspace'
  belongs_to :knowledge_base,
             class_name: 'ChatRing::KnowledgeBase',
             inverse_of: :knowledge_indexes
  has_many :documents,
           class_name: 'ChatRing::KnowledgeDocument',
           inverse_of: :knowledge_index,
           dependent: :destroy
  has_one :provider_cleanup,
          class_name: 'ChatRing::KnowledgeProviderCleanup',
          inverse_of: :knowledge_index,
          dependent: nil

  encrypts :provider_agent_api_key

  validates :status, inclusion: { in: STATUSES }
  validates :provider, :provider_release, presence: true
  validate :workspace_matches_knowledge_base
  validate :completed_snapshot_is_immutable, on: :update
  validate :discarded_index_has_reason
  validate :discarded_index_is_terminal, on: :update

  scope :active, -> { where(status: 'active') }

  def fail!(code:, message:)
    update!(status: 'failed', failure_code: code.to_s, failure_message: message.to_s.truncate(1000))
  end

  def provider_binding_digest
    document_hashes = documents.order(:id).pluck(:content_hash)
    Digest::SHA256.hexdigest(
      [workspace_id, knowledge_base_id, manifest_digest, provider_release, config_snapshot, document_hashes].to_json
    )
  end

  def account
    workspace.chatwoot_account
  end

  def account_id
    workspace.chatwoot_account_id
  end

  private

  def workspace_matches_knowledge_base
    return if workspace.blank? || knowledge_base.blank? || knowledge_base.workspace_id == workspace_id

    errors.add(:knowledge_base, 'must belong to the selected Workspace')
  end

  def discarded_index_has_reason
    return unless status == 'discarded'
    return if discarded_at.present? && discard_reason.present?

    errors.add(:base, 'discarded provider index requires a timestamp and reason')
  end

  def discarded_index_is_terminal
    return unless attribute_in_database('status') == 'discarded' && will_save_change_to_status?

    errors.add(:status, 'cannot change after the provider index is discarded')
  end

  def completed_snapshot_is_immutable
    return unless IMMUTABLE_STATUSES.include?(attribute_in_database('status'))
    return unless IMMUTABLE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'completed provider index snapshot is immutable')
  end
end
