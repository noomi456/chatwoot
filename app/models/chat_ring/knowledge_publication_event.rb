class ChatRing::KnowledgePublicationEvent < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_publication_events'

  ACTIONS = %w[publish rollback].freeze

  belongs_to :account
  belongs_to :inbox
  belongs_to :from_knowledge_version, class_name: 'ChatRing::KnowledgeVersion', optional: true
  belongs_to :to_knowledge_version, class_name: 'ChatRing::KnowledgeVersion'

  validates :action, inclusion: { in: ACTIONS }
  validate :versions_belong_to_scope

  private

  def versions_belong_to_scope
    [from_knowledge_version, to_knowledge_version].compact.each do |version|
      next if version.account_id == account_id && version.inbox_id == inbox_id

      errors.add(:to_knowledge_version, 'must belong to the event account and inbox')
    end
  end
end
