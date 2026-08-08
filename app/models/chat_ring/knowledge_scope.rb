class ChatRing::KnowledgeScope < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_scopes'

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :knowledge_scopes
  has_many :material_rules,
           class_name: 'ChatRing::KnowledgeScopeMaterial',
           inverse_of: :knowledge_scope,
           dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :workspace_id }
end
