class ChatRing::KnowledgeProviderCleanup < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_provider_cleanups'

  STATUSES = %w[pending retrying succeeded cancelled failed].freeze

  belongs_to :knowledge_version,
             class_name: 'ChatRing::KnowledgeVersion',
             inverse_of: :provider_cleanup,
             optional: true

  validates :account_id, :inbox_id, :knowledge_version_id, :provider_source_id, :binding_digest, :eligible_at, presence: true
  validates :knowledge_version_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :binding_digest, format: { with: /\A[0-9a-f]{64}\z/ }
end
