class ChatRing::Brain::DecisionSchema < RubyLLM::Schema
  string :decision_type,
         description: 'One of reply, clarification, playbook, request_appointment, handoff, or abstain.'
  string :response_text,
         description: 'Customer-facing plain text for reply, clarification, or grounded Playbook side answer; otherwise empty.',
         max_length: 4000
  string :reason_code,
         description: 'Short stable snake_case reason for the decision.',
         max_length: 80
  array :evidence_ids,
        description: 'Only evidence IDs supplied in the prompt and directly supporting the decision.',
        max_items: 8,
        of: :string
  object :tool_request,
         description: 'Registered semantic Tool request. Omit unless decision_type is request_appointment.',
         required: false do
    string :key, description: 'Registered Tool key.'
    integer :version, description: 'Registered immutable Tool version.'
    object :arguments, description: 'Arguments allowed by the registered Tool schema.' do
      string :requested_time_window, description: 'Optional visitor-requested time window.', max_length: 160, required: false
      string :reason_code, description: 'Optional stable snake_case request reason.', max_length: 80, required: false
    end
  end
  object :playbook_control,
         description: 'Semantic Playbook action. Omit unless decision_type is playbook.',
         required: false do
    string :action,
           description: 'One of submit_answer, answer_side_question, submit_answer_and_answer_side_question, or resume_pending_question.'
    string :answer_value,
           description: 'Normalized answer or exact supplied choice value. Required only when submitting an answer.',
           max_length: 1000,
           required: false
  end
end
