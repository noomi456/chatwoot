class ChatRing::KnowledgeDocument < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_documents'

  PROVIDER_STATUSES = %w[pending processing ready failed].freeze
  MAX_MARKDOWN_LENGTH = 2.megabytes

  belongs_to :knowledge_version,
             class_name: 'ChatRing::KnowledgeVersion',
             inverse_of: :documents

  validates :source_url, :markdown, :content_hash, :provider_file_name, presence: true
  validates :markdown, length: { maximum: MAX_MARKDOWN_LENGTH }
  validates :provider_status, inclusion: { in: PROVIDER_STATUSES }
end
