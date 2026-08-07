class ChatRing::KnowledgeDocument < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_documents'

  PROVIDER_STATUSES = %w[pending processing ready failed].freeze
  SOURCE_KINDS = %w[website pdf docx].freeze
  MAX_MARKDOWN_LENGTH = 2.megabytes
  IMMUTABLE_SNAPSHOT_ATTRIBUTES = %w[
    source_kind source_reference source_url public_url file_source_id title markdown content_hash provider_file_name metadata
  ].freeze

  belongs_to :knowledge_version,
             class_name: 'ChatRing::KnowledgeVersion',
             inverse_of: :documents
  belongs_to :file_source,
             class_name: 'ChatRing::KnowledgeFileSource',
             inverse_of: :knowledge_documents,
             optional: true

  before_validation :derive_website_references

  validates :source_reference, :markdown, :content_hash, :provider_file_name, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :markdown, length: { maximum: MAX_MARKDOWN_LENGTH }
  validates :provider_status, inclusion: { in: PROVIDER_STATUSES }
  validate :source_locator_matches_kind
  validate :completed_version_snapshot_is_immutable

  private

  def derive_website_references
    return unless source_kind == 'website' && source_url.present?

    self.source_reference ||= source_url
    self.public_url ||= source_url
  end

  def source_locator_matches_kind
    if source_kind == 'website'
      errors.add(:public_url, 'is required for website evidence') if public_url.blank?
      errors.add(:source_url, 'is required for website evidence') if source_url.blank?
    elsif file_source_id.blank?
      errors.add(:file_source, 'is required for file evidence')
    end
  end

  def completed_version_snapshot_is_immutable
    return if knowledge_version.blank?
    return unless ChatRing::KnowledgeVersion::IMMUTABLE_BUILD_STATUSES.include?(knowledge_version.status)

    snapshot_changed = IMMUTABLE_SNAPSHOT_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
    return unless new_record? || snapshot_changed

    errors.add(:base, 'completed knowledge document snapshot is immutable')
  end
end
