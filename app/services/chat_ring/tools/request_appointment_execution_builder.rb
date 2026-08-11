require 'digest'

class ChatRing::Tools::RequestAppointmentExecutionBuilder
  def self.call(turn:, outbound_commit:, authorization:, arguments:, authorization_result:)
    ChatRing::ToolExecution.create!(
      ai_turn: turn,
      inbox_tool_policy_version: authorization.policy_version,
      outbound_commit: outbound_commit,
      tool_key: 'request_appointment',
      tool_version: 1,
      status: :pending,
      validated_arguments: arguments,
      result_payload: authorization.renderer_result.payload,
      authorization_result: authorization_result,
      renderer: authorization.capability.renderer,
      rendered_content: authorization.renderer_result.content,
      idempotency_key: Digest::SHA256.hexdigest("chatring:tool:#{turn.workspace_id}:#{turn.id}:request_appointment@1")
    )
  end
end
