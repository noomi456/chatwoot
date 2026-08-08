class ChatRing::KnowledgeBase < ApplicationRecord
  self.table_name = 'chat_ring_knowledge_bases'

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :knowledge_base
  belongs_to :active_knowledge_index, class_name: 'ChatRing::KnowledgeIndex', optional: true
  has_many :knowledge_indexes,
           class_name: 'ChatRing::KnowledgeIndex',
           inverse_of: :knowledge_base,
           dependent: :destroy
  has_many :website_sources,
           class_name: 'ChatRing::KnowledgeWebsiteSource',
           inverse_of: :knowledge_base,
           dependent: :destroy
  has_many :file_sources,
           class_name: 'ChatRing::KnowledgeFileSource',
           inverse_of: :knowledge_base,
           dependent: :destroy
  has_many :materials,
           class_name: 'ChatRing::KnowledgeMaterial',
           inverse_of: :knowledge_base,
           dependent: :destroy
  has_many :provider_cleanups,
           class_name: 'ChatRing::KnowledgeProviderCleanup',
           inverse_of: :knowledge_base,
           dependent: :nullify

  validates :workspace_id, uniqueness: true
  validate :active_index_belongs_to_base

  def self.for_account!(account)
    workspace = ChatRing::Workspace.for_account!(account)
    knowledge_base = create_or_find_by!(workspace: workspace)
    workspace.knowledge_scopes.create_or_find_by!(name: 'Business-wide') do |scope|
      scope.business_wide = true
    end
    knowledge_base
  end

  private

  def active_index_belongs_to_base
    return if active_knowledge_index.blank? || active_knowledge_index.knowledge_base_id == id

    errors.add(:active_knowledge_index, 'belongs to another knowledge base')
  end
end
