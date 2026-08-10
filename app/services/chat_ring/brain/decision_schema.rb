class ChatRing::Brain::DecisionSchema < RubyLLM::Schema
  string :decision_type,
         description: 'One of reply, clarification, handoff, or abstain.'
  string :response_text,
         description: 'Customer-facing plain text for reply or clarification; otherwise an empty string.',
         max_length: 4000
  string :reason_code,
         description: 'Short stable snake_case reason for the decision.',
         max_length: 80
  array :evidence_ids,
        description: 'Only evidence IDs supplied in the prompt and directly supporting the decision.',
        max_items: 8,
        of: :string
end
