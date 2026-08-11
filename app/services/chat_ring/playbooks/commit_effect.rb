class ChatRing::Playbooks::CommitEffect
  class Invalid < StandardError; end

  def self.applicable?(turn)
    turn.decision_payload.to_h.dig('playbook_control', 'action').present?
  end

  def initialize(turn:, execution:)
    @turn = turn
    @execution = execution
  end

  def failure_code
    return 'playbook_commit_control_invalid' unless control
    return 'playbook_commit_control_stale' unless execution_matches_turn?
    return 'playbook_execution_not_active' unless execution.status_active?
    return 'playbook_trigger_changed' unless execution.last_trigger_message_id == turn.trigger_message_id
    return 'playbook_commit_action_unsupported' unless control['action'] == 'ask_current_step'
    return 'playbook_step_unsupported' unless question_step?
  end

  def message_attributes
    return {} if failure_code

    {
      content: ChatRing::Playbooks::QuestionRenderer.call(execution.current_step),
      content_type: 'text'
    }
  end

  def apply!(message)
    raise Invalid, failure_code if failure_code

    mark_question_asked!(message)
  end

  private

  attr_reader :turn, :execution

  def control
    @control ||= begin
      value = turn.decision_payload['playbook_control']
      value.to_h.deep_stringify_keys if value.respond_to?(:to_h)
    end
  end

  def execution_matches_turn?
    execution.id == turn.inbox_playbook_execution_id &&
      execution.lock_version == turn.playbook_execution_lock_version &&
      execution.current_step_id == turn.playbook_step_id
  end

  def question_step?
    %w[ask_text ask_choice].include?(execution.current_step.to_h['kind'])
  end

  def mark_question_asked!(message)
    execution.update!(
      status: :waiting_for_customer,
      last_outcome_message: message,
      transition_history: execution.transition_history + [transition_record(message)]
    )
  end

  def transition_record(message)
    {
      'action' => 'ask_current_step',
      'step_id' => execution.current_step_id,
      'trigger_message_id' => turn.trigger_message_id,
      'outcome_message_id' => message.id,
      'committed_at' => Time.current.iso8601(6)
    }
  end
end
