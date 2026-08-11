class ChatRing::Brain::DecisionSchema < RubyLLM::Schema
  string :decision_type,
         description: 'One of reply, clarification, context_reply, playbook, request_appointment, handoff, or abstain.'
  string :response_text,
         description: 'Customer-facing plain text for reply, clarification, context_reply, or grounded Playbook side answer; otherwise empty.',
         max_length: 4000
  string :reason_code,
         description: 'Short stable snake_case reason for the decision.',
         max_length: 80
  array :evidence_ids,
        description: 'Only evidence IDs supplied in the prompt and directly supporting the decision.',
        max_items: 8,
        of: :string
  array :suggested_questions,
        description: 'Zero to two short visitor-facing next questions grounded in the accepted evidence; empty during an active Playbook.',
        max_items: 2,
        of: :string
  array :response_options,
        description: 'Zero to six short answer options for a single customer-facing choice question; ' \
                     'empty unless the response text asks that question.',
        max_items: 6,
        of: :string
  array :microsite_section_types,
        description: 'Zero to three useful grounded microsite section types. Empty for weak evidence, close-ended answers, ' \
                     'active Playbooks, Tools, handoff, or abstention.',
        max_items: 3,
        of: :string
  any_of :tool_request,
         description: 'Registered semantic Tool request, or null unless decision_type is request_appointment.' do
    object do
      string :key, description: 'Registered Tool key.'
      integer :version, description: 'Registered immutable Tool version.'
      object :arguments, description: 'Arguments allowed by the registered Tool schema.' do
        any_of :requested_time_window, description: 'Optional visitor-requested time window.' do
          string max_length: 160
          null
        end
        any_of :reason_code, description: 'Optional stable snake_case request reason.' do
          string max_length: 80
          null
        end
      end
    end
    null
  end
  any_of :playbook_control,
         description: 'Semantic Playbook action, or null unless decision_type is playbook.' do
    object do
      string :action,
             description: 'One of submit_answer, answer_side_question, submit_answer_and_answer_side_question, or resume_pending_question.'
      any_of :answer_value,
             description: 'Normalized answer or exact supplied choice value, or null when not submitting an answer.' do
        string max_length: 1000
        null
      end
    end
    null
  end
end
