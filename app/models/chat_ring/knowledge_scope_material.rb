class ChatRing::KnowledgeScopeMaterial < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_scope_materials'

  ACCESS_VALUES = %w[allow deny].freeze

  belongs_to :knowledge_scope, class_name: 'ChatRing::KnowledgeScope', inverse_of: :material_rules
  belongs_to :knowledge_material, class_name: 'ChatRing::KnowledgeMaterial'

  validates :knowledge_material_id, uniqueness: { scope: :knowledge_scope_id }
  validates :access, inclusion: { in: ACCESS_VALUES }
  validate :material_belongs_to_workspace

  private

  def material_belongs_to_workspace
    return if knowledge_scope.blank? || knowledge_material.blank?
    return if knowledge_scope.workspace_id == knowledge_material.knowledge_base.workspace_id

    errors.add(:knowledge_material, 'belongs to another Workspace')
  end
end
