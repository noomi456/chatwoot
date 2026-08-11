class ChatRing::AssistantDraft < ApplicationRecord
  include ChatRing::ToolGrantNormalizable

  self.table_name = 'chat_ring_assistant_drafts'

  CONFIGURATION_ATTRIBUTES = %i[
    identity goals instructions response_guidelines guardrails audience_policy availability_policy handoff_policy tool_grants
    conversation_policy llm_provider llm_model
  ].freeze
  HANDOFF_REASONS = %w[on_insufficient_evidence on_provider_failure].freeze
  HANDOFF_OUTCOMES = %w[abstain handoff].freeze

  belongs_to :assistant, class_name: 'ChatRing::Assistant', inverse_of: :configuration_draft
  belongs_to :knowledge_scope, class_name: 'ChatRing::KnowledgeScope'
  belongs_to :published_version, class_name: 'ChatRing::AssistantVersion', optional: true

  validates :assistant_id, uniqueness: true
  validates :llm_provider, inclusion: { in: %w[openai] }
  validate :llm_model_is_supported
  validate :configuration_shapes
  validate :tool_grants_are_registered
  validate :handoff_policy_is_supported
  validate :knowledge_scope_belongs_to_workspace
  validate :published_version_belongs_to_assistant

  def published_configuration
    attributes.symbolize_keys.slice(*CONFIGURATION_ATTRIBUTES)
  end

  private

  def configuration_shapes
    errors.add(:identity, 'must be an object') unless identity.is_a?(Hash)
    validate_string_array(:goals)
    validate_string_array(:response_guidelines)
    validate_string_array(:guardrails)
    validate_object_configuration
    errors.add(:tool_grants, 'must be an array') unless tool_grants.is_a?(Array)
  end

  def validate_object_configuration
    errors.add(:handoff_policy, 'must be an object') unless handoff_policy.is_a?(Hash)
    errors.add(:audience_policy, 'must be an object') unless audience_policy.is_a?(Hash)
    errors.add(:availability_policy, 'must be an object') unless availability_policy.is_a?(Hash)
    errors.add(:conversation_policy, 'must be an object') unless conversation_policy.is_a?(Hash)
  end

  def validate_string_array(attribute)
    value = public_send(attribute)
    return errors.add(attribute, 'must be an array of text values') unless value.is_a?(Array)
    return if value.all? { |item| item.is_a?(String) && item.present? }

    errors.add(attribute, 'must contain only non-empty text values')
  end

  def handoff_policy_is_supported
    return unless handoff_policy.is_a?(Hash)

    unsupported_keys = handoff_policy.keys.map(&:to_s) - HANDOFF_REASONS
    errors.add(:handoff_policy, 'contains unsupported reasons') if unsupported_keys.any?
    return if handoff_policy.values.all? { |outcome| HANDOFF_OUTCOMES.include?(outcome.to_s) }

    errors.add(:handoff_policy, 'contains an unsupported outcome')
  end

  def tool_grants_are_registered
    ChatRing::Tools::GrantSet.new(tool_grants)
  rescue ChatRing::Tools::GrantSet::Invalid => e
    errors.add(:tool_grants, e.message)
  end

  def knowledge_scope_belongs_to_workspace
    return if assistant.blank? || knowledge_scope.blank? || knowledge_scope.workspace_id == assistant.workspace_id

    errors.add(:knowledge_scope, 'must belong to the Assistant Workspace')
  end

  def published_version_belongs_to_assistant
    return if published_version.blank? || published_version.assistant_id == assistant_id

    errors.add(:published_version, 'must belong to the Assistant')
  end

  def llm_model_is_supported
    return if llm_model == 'gpt-5.4'
    return if published_version.present? && llm_model == published_version.llm_model

    errors.add(:llm_model, 'must remain on the published model or use gpt-5.4')
  end
end
