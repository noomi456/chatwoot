class ChatRing::KnowledgeMaterial < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_materials'

  SOURCE_KINDS = %w[website pdf docx doc odt rtf xlsx xls html].freeze
  STATUSES = %w[processing available updating refresh_failed failed].freeze
  AUTHORITY_CLASSES = %w[
    product_documentation structured_commercial marketing approved_legal_policy approved_compliance
  ].freeze

  belongs_to :knowledge_base, class_name: 'ChatRing::KnowledgeBase', inverse_of: :materials
  belongs_to :website_source,
             class_name: 'ChatRing::KnowledgeWebsiteSource',
             inverse_of: :materials,
             optional: true
  belongs_to :file_source,
             class_name: 'ChatRing::KnowledgeFileSource',
             inverse_of: :materials,
             optional: true
  has_many :knowledge_documents,
           class_name: 'ChatRing::KnowledgeDocument',
           inverse_of: :knowledge_material,
           dependent: :restrict_with_exception

  before_validation :ensure_material_key, on: :create

  validates :material_key, :source_reference, presence: true
  validates :source_reference, uniqueness: { scope: :knowledge_base_id }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :authority_class, inclusion: { in: AUTHORITY_CLASSES }
  validates :content_hash, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :markdown, length: { maximum: ChatRing::KnowledgeDocument::MAX_MARKDOWN_LENGTH }
  validate :exactly_one_source
  validate :website_has_public_url
  validate :available_snapshot_is_complete

  scope :active, -> { where(deleted_at: nil) }
  scope :retrievable, -> { active.where('markdown IS NOT NULL AND content_hash IS NOT NULL AND extracted_at IS NOT NULL') }

  def active?
    deleted_at.nil?
  end

  private

  def ensure_material_key
    self.material_key ||= SecureRandom.uuid
  end

  def exactly_one_source
    return if website_source.present? ^ file_source.present?

    errors.add(:base, 'knowledge material must belong to exactly one website or file source')
  end

  def website_has_public_url
    errors.add(:public_url, 'is required for website material') if source_kind == 'website' && public_url.blank?
  end

  def available_snapshot_is_complete
    return unless status == 'available'
    return if markdown.present? && content_hash.present? && extracted_at.present?

    errors.add(:base, 'available knowledge material requires extracted content')
  end
end
