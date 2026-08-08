class ChatRing::KnowledgeWebsiteSource < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_website_sources'

  STATUSES = %w[mapping mapped extracting available refreshing refresh_failed failed deleted].freeze
  SOURCE_TYPES = %w[website webpage].freeze

  belongs_to :knowledge_base, class_name: 'ChatRing::KnowledgeBase', inverse_of: :website_sources
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :materials,
           class_name: 'ChatRing::KnowledgeMaterial',
           foreign_key: :website_source_id,
           inverse_of: :website_source,
           dependent: :destroy

  before_validation :ensure_source_key, on: :create

  validates :source_key, :root_url, presence: true
  validates :root_url, uniqueness: { scope: [:knowledge_base_id, :source_type] }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :visible, -> { where.not(status: 'deleted') }

  private

  def ensure_source_key
    self.source_key ||= SecureRandom.uuid
  end
end
