class ChatRing::KnowledgeDocument < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_documents'

  PROVIDER_STATUSES = %w[pending processing ready failed].freeze
  MAX_MARKDOWN_LENGTH = 2.megabytes
  IMMUTABLE_SNAPSHOT_ATTRIBUTES = %w[source_url title markdown content_hash provider_file_name metadata].freeze

  belongs_to :knowledge_version,
             class_name: 'ChatRing::KnowledgeVersion',
             inverse_of: :documents

  validates :source_url, :markdown, :content_hash, :provider_file_name, presence: true
  validates :markdown, length: { maximum: MAX_MARKDOWN_LENGTH }
  validates :provider_status, inclusion: { in: PROVIDER_STATUSES }
  validate :completed_version_snapshot_is_immutable

  private

  def completed_version_snapshot_is_immutable
    return if knowledge_version.blank?
    return unless ChatRing::KnowledgeVersion::IMMUTABLE_BUILD_STATUSES.include?(knowledge_version.status)

    snapshot_changed = IMMUTABLE_SNAPSHOT_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
    return unless new_record? || snapshot_changed

    errors.add(:base, 'completed knowledge document snapshot is immutable')
  end
end
