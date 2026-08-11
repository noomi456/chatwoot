require 'json_schemer'

class ChatRing::ToolExecution < ApplicationRecord
  self.table_name = 'chat_ring_tool_executions'

  enum status: { pending: 0, committed: 1, rejected: 2, failed: 3 }, _prefix: true

  belongs_to :ai_turn, class_name: 'ChatRing::AiTurn', inverse_of: :tool_execution
  belongs_to :inbox_tool_policy_version,
             class_name: 'ChatRing::InboxToolPolicyVersion',
             inverse_of: :tool_executions
  belongs_to :outbound_commit, class_name: 'ChatRing::OutboundCommit', inverse_of: :tool_execution

  validates :ai_turn_id, :outbound_commit_id, :idempotency_key, uniqueness: true
  validates :tool_key, :authorization_result, :renderer, :rendered_content, presence: true
  validates :tool_version, numericality: { only_integer: true, greater_than: 0 }
  validates :idempotency_key, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :tool_definition_exists
  validate :payload_shapes
  validate :payloads_match_registered_schemas
  validate :native_scope_matches

  attr_readonly :ai_turn_id,
                :inbox_tool_policy_version_id,
                :outbound_commit_id,
                :tool_key,
                :tool_version,
                :validated_arguments,
                :result_payload,
                :authorization_result,
                :renderer,
                :rendered_content,
                :idempotency_key

  def mark_committed!(timestamp: Time.current)
    return if status_committed?

    update!(status: :committed, failure_code: nil, attempted_at: attempted_at || timestamp, committed_at: timestamp)
  end

  def mark_rejected!(failure_code, timestamp: Time.current)
    return if status_committed? || status_rejected?

    update!(status: :rejected, failure_code: failure_code, attempted_at: attempted_at || timestamp)
  end

  private

  def tool_definition_exists
    ChatRing::Tools::Registry.fetch(tool_key, tool_version)
  rescue KeyError
    errors.add(:tool_key, 'does not identify a registered Tool version')
  end

  def payload_shapes
    errors.add(:validated_arguments, 'must be an object') unless validated_arguments.is_a?(Hash)
    errors.add(:result_payload, 'must be an object') unless result_payload.is_a?(Hash)
  end

  def payloads_match_registered_schemas
    return unless validated_arguments.is_a?(Hash) && result_payload.is_a?(Hash)

    definition = ChatRing::Tools::Registry.fetch(tool_key, tool_version)
    unless JSONSchemer.schema(definition.input_schema).valid?(validated_arguments)
      errors.add(:validated_arguments, 'do not match the registered Tool schema')
    end
    return if JSONSchemer.schema(definition.output_schema).valid?(result_payload)

    errors.add(:result_payload, 'does not match the registered Tool schema')
  rescue KeyError
    nil
  end

  def native_scope_matches
    return if ai_turn.blank? || inbox_tool_policy_version.blank?

    policy = inbox_tool_policy_version.inbox_tool_policy
    errors.add(:inbox_tool_policy_version, 'must belong to the AITurn Workspace') unless policy.workspace_id == ai_turn.workspace_id
    return if policy.chatwoot_inbox_id == ai_turn.conversation.inbox_id

    errors.add(:inbox_tool_policy_version, 'must belong to the AITurn Inbox')
  end
end
