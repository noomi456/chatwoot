class ChatRing::KnowledgePublication < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_publications'

  belongs_to :account
  belongs_to :inbox
  belongs_to :knowledge_version, class_name: 'ChatRing::KnowledgeVersion'
  belongs_to :previous_knowledge_version, class_name: 'ChatRing::KnowledgeVersion', optional: true

  validates :inbox_id, uniqueness: { scope: :account_id }
  validate :versions_belong_to_scope

  private

  def versions_belong_to_scope
    [knowledge_version, previous_knowledge_version].compact.each do |version|
      next if version.account_id == account_id && version.inbox_id == inbox_id

      errors.add(:knowledge_version, 'must belong to the publication account and inbox')
    end
  end
end
