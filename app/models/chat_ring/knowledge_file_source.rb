class ChatRing::KnowledgeFileSource < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_file_sources'

  STATUSES = %w[uploaded parsing ready parse_indeterminate failed disabled].freeze
  SOURCE_KINDS = %w[pdf docx].freeze
  AUTHORITY_CLASSES = %w[
    product_documentation structured_commercial marketing approved_legal_policy approved_compliance
  ].freeze
  MAX_FILE_SIZE = 50.megabytes
  IMMUTABLE_PARSE_ATTRIBUTES = %w[
    account_id inbox_id source_key source_kind original_filename content_type byte_size raw_content_hash
    parser_profile parser_profile_digest markdown content_hash metadata parsed_at
  ].freeze

  belongs_to :account
  belongs_to :inbox
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :approved_by, class_name: 'User', optional: true
  has_many :knowledge_documents,
           class_name: 'ChatRing::KnowledgeDocument',
           foreign_key: :file_source_id,
           inverse_of: :file_source,
           dependent: :nullify
  has_one_attached :file

  before_validation :ensure_source_key, on: :create

  validates :status, inclusion: { in: STATUSES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :authority_class, inclusion: { in: AUTHORITY_CLASSES }
  validates :source_key, :original_filename, :content_type, :raw_content_hash, :parser_profile_digest, presence: true
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_FILE_SIZE }
  validates :raw_content_hash, :parser_profile_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :content_hash, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :markdown, length: { maximum: ChatRing::KnowledgeDocument::MAX_MARKDOWN_LENGTH }, allow_nil: true
  validate :inbox_belongs_to_account
  validate :ready_snapshot_is_complete
  validate :parsed_snapshot_is_immutable, on: :update

  scope :available, -> { where.not(status: 'disabled') }
  scope :ready, -> { where(status: 'ready') }

  def source_reference
    "urn:chatring:knowledge-file:#{source_key}"
  end

  private

  def ensure_source_key
    self.source_key ||= SecureRandom.uuid
  end

  def inbox_belongs_to_account
    return if inbox.blank? || account.blank? || inbox.account_id == account_id

    errors.add(:inbox, 'must belong to the selected account')
  end

  def ready_snapshot_is_complete
    return unless status == 'ready'
    return if markdown.present? && content_hash.present? && parsed_at.present? && file.attached?

    errors.add(:base, 'ready file source requires an attached file and complete parsed snapshot')
  end

  def parsed_snapshot_is_immutable
    return unless attribute_in_database('status').in?(%w[ready disabled])
    return unless IMMUTABLE_PARSE_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'parsed file-source snapshot is immutable')
  end
end
