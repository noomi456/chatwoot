class ChatRing::KnowledgeVersion < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_versions'

  STATUSES = %w[pending crawling ingesting ready published retired failed].freeze

  belongs_to :account
  belongs_to :inbox
  has_many :documents,
           class_name: 'ChatRing::KnowledgeDocument',
           foreign_key: :knowledge_version_id,
           inverse_of: :knowledge_version,
           dependent: :destroy

  encrypts :provider_agent_api_key

  validates :status, inclusion: { in: STATUSES }
  validates :provider, :provider_release, :root_url, presence: true
  validate :inbox_belongs_to_account

  scope :published, -> { where(status: 'published') }

  def fail!(code:, message:)
    update!(status: 'failed', failure_code: code.to_s, failure_message: message.to_s.truncate(1000))
  end

  private

  def inbox_belongs_to_account
    return if inbox.blank? || account.blank? || inbox.account_id == account_id

    errors.add(:inbox, 'must belong to the selected account')
  end
end
