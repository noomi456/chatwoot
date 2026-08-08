class ChatRing::AssistantVersion < ApplicationRecord
  self.table_name = 'chat_ring_assistant_versions'

  ARRAY_ATTRIBUTES = %w[goals response_guidelines guardrails tool_grants].freeze
  OBJECT_ATTRIBUTES = %w[identity audience_policy availability_policy handoff_policy conversation_policy].freeze

  belongs_to :assistant, class_name: 'ChatRing::Assistant', inverse_of: :versions
  belongs_to :knowledge_scope, class_name: 'ChatRing::KnowledgeScope'
  has_many :ai_turns,
           class_name: 'ChatRing::AiTurn',
           inverse_of: :assistant_version,
           dependent: :restrict_with_exception

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :assistant_id }
  validates :published_at, presence: true
  validates :llm_provider, :llm_model, presence: true
  validate :configuration_shapes
  validate :knowledge_scope_belongs_to_workspace
  validate :published_snapshot_is_immutable, on: :update

  private

  def configuration_shapes
    ARRAY_ATTRIBUTES.each { |attribute| errors.add(attribute, 'must be an array') unless public_send(attribute).is_a?(Array) }
    OBJECT_ATTRIBUTES.each { |attribute| errors.add(attribute, 'must be an object') unless public_send(attribute).is_a?(Hash) }
  end

  def knowledge_scope_belongs_to_workspace
    return if assistant.blank? || knowledge_scope.blank? || knowledge_scope.workspace_id == assistant.workspace_id

    errors.add(:knowledge_scope, 'must belong to the Assistant Workspace')
  end

  def published_snapshot_is_immutable
    return if changed_attribute_names_to_save.empty?

    errors.add(:base, 'published Assistant version is immutable')
  end
end
