require 'rails_helper'

RSpec.describe ChatRing::Brain::Decision do
  it 'accepts a grounded reply citing only supplied evidence' do
    decision = described_class.from_payload(
      {
        decision_type: 'reply', response_text: 'The product supports widgets.', reason_code: 'answered',
        evidence_ids: ['evidence-1']
      },
      allowed_evidence_ids: ['evidence-1'],
      evidence_status: 'accepted'
    )

    expect(decision.to_h).to include('decision_type' => 'reply', 'evidence_ids' => ['evidence-1'])
  end

  it 'accepts two grounded suggestions and three normalized microsite sections' do
    decision = described_class.from_payload(
      {
        decision_type: 'reply', response_text: 'Verified answer', reason_code: 'answered',
        evidence_ids: ['evidence-1'], suggested_questions: ['How much is it?', 'Can I book?'],
        microsite_section_types: %w[hero features faq]
      },
      allowed_evidence_ids: ['evidence-1'],
      evidence_status: 'accepted'
    )

    expect(decision.to_h).to include(
      'suggested_questions' => ['How much is it?', 'Can I book?'],
      'microsite_section_types' => %w[hero features_grid faq_accordion]
    )
  end

  it 'accepts bounded options for one clarification question and keeps them separate from next-question suggestions' do
    decision = described_class.from_payload(
      {
        decision_type: 'clarification', response_text: 'Which usage fits your household?', reason_code: 'qualify_usage',
        evidence_ids: [], response_options: ['Light Usage', 'Standard Usage', 'Heavy Usage']
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence'
    )

    expect(decision.response_options).to eq(['Light Usage', 'Standard Usage', 'Heavy Usage'])

    expect do
      described_class.from_payload(
        {
          decision_type: 'reply', response_text: 'Choose one.', reason_code: 'choose', evidence_ids: ['evidence-1'],
          response_options: ['A', 'B'], suggested_questions: ['What next?']
        },
        allowed_evidence_ids: ['evidence-1'],
        evidence_status: 'accepted'
      )
    end.to raise_error(described_class::Invalid, 'Response options cannot be mixed with suggested questions')
  end

  it 'rejects suggestions and microsites when the answer is not grounded' do
    expect do
      described_class.from_payload(
        {
          decision_type: 'clarification', response_text: 'Could you clarify?', reason_code: 'clarify',
          evidence_ids: [], suggested_questions: ['What does it cost?'], microsite_section_types: ['hero']
        },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid)
  end

  it 'rejects unsupported microsite section names rather than rendering model-defined components' do
    expect do
      described_class.from_payload(
        {
          decision_type: 'reply', response_text: 'Verified answer', reason_code: 'answered',
          evidence_ids: ['evidence-1'], microsite_section_types: ['arbitrary_iframe']
        },
        allowed_evidence_ids: ['evidence-1'],
        evidence_status: 'accepted'
      )
    end.to raise_error(described_class::Invalid, 'Unknown microsite section types: arbitrary_iframe')
  end

  it 'rejects a factual reply without accepted evidence' do
    expect do
      described_class.from_payload(
        { decision_type: 'reply', response_text: 'Unsupported claim', reason_code: 'answered', evidence_ids: [] },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid, 'Grounded replies require accepted evidence')
  end

  it 'accepts a history-only Conversation reply and rejects it without native history' do
    decision = described_class.from_payload(
      {
        decision_type: 'context_reply', response_text: 'You previously asked about pricing.',
        reason_code: 'conversation_history', evidence_ids: []
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence',
      conversation_history_available: true
    )

    expect(decision.to_h).to include('decision_type' => 'context_reply', 'evidence_ids' => [])

    expect do
      described_class.from_payload(
        {
          decision_type: 'context_reply', response_text: 'You previously asked about pricing.',
          reason_code: 'conversation_history', evidence_ids: []
        },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid, 'Conversation replies require prior public history')
  end

  it 'rejects evidence IDs that were not supplied to the model' do
    expect do
      described_class.from_payload(
        { decision_type: 'reply', response_text: 'Claim', reason_code: 'answered', evidence_ids: ['invented'] },
        allowed_evidence_ids: ['evidence-1'],
        evidence_status: 'accepted'
      )
    end.to raise_error(described_class::Invalid, 'Brain cited evidence outside the supplied set')
  end

  it 'rejects resolution requests until a native audited operation exists' do
    expect do
      described_class.from_payload(
        { decision_type: 'resolution_request', response_text: '', reason_code: 'resolved', evidence_ids: [] },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid, 'Unknown Brain decision type')
  end

  it 'accepts only the registered semantic appointment Tool without a model-controlled URL' do
    decision = described_class.from_payload(
      {
        decision_type: 'request_appointment', response_text: '', reason_code: 'visitor_requested_demo', evidence_ids: [],
        tool_request: {
          key: 'request_appointment', version: 1,
          arguments: { requested_time_window: 'next week', reason_code: 'visitor_requested_demo' }
        }
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence'
    )

    expect(decision.tool_request.definition.identifier).to eq('request_appointment@1')
    expect(decision.to_h.dig('tool_request', 'arguments')).not_to have_key('url')

    expect do
      described_class.from_payload(
        {
          decision_type: 'request_appointment', response_text: '', reason_code: 'visitor_requested_demo', evidence_ids: [],
          tool_request: { key: 'request_appointment', version: 1, arguments: { url: 'https://attacker.example' } }
        },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid, 'Tool request arguments do not match the registered schema')
  end

  it 'accepts a typed Playbook answer without evidence but no model-selected runtime identifiers' do
    decision = described_class.from_payload(
      {
        decision_type: 'playbook', response_text: '', reason_code: 'answered_pending_question', evidence_ids: [],
        playbook_control: { action: 'submit_answer', answer_value: 'internet' }
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence',
      playbook_context: { 'pending_question' => 'What service do you need?' }
    )

    expect(decision.to_h.fetch('playbook_control')).to eq(
      'action' => 'submit_answer', 'answer_value' => 'internet'
    )
  end

  it 'requires accepted evidence for a Playbook side answer and rejects trusted runtime fields' do
    expect do
      described_class.from_payload(
        {
          decision_type: 'playbook', response_text: 'Installation is included.', reason_code: 'side_question',
          evidence_ids: [], playbook_control: { action: 'answer_side_question', execution_id: 42 }
        },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence',
        playbook_context: { 'pending_question' => 'What service do you need?' }
      )
    end.to raise_error(described_class::Invalid, 'Playbook control contains unknown fields')

    expect do
      described_class.from_payload(
        {
          decision_type: 'playbook', response_text: 'Installation is included.', reason_code: 'side_question',
          evidence_ids: [], playbook_control: { action: 'answer_side_question' }
        },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence',
        playbook_context: { 'pending_question' => 'What service do you need?' }
      )
    end.to raise_error(described_class::Invalid, 'Grounded Playbook side answers require accepted evidence')
  end

  it 'does not allow an ordinary reply to bypass exact pending-question resume in an active Playbook' do
    expect do
      described_class.from_payload(
        {
          decision_type: 'reply', response_text: 'Widgets are supported.', reason_code: 'answered',
          evidence_ids: ['evidence-1']
        },
        allowed_evidence_ids: ['evidence-1'],
        evidence_status: 'accepted',
        playbook_context: { 'pending_question' => 'What service do you need?' }
      )
    end.to raise_error(described_class::Invalid, 'Active Playbook replies must use typed Playbook control')
  end

  it 'accepts a typed no-evidence resume and rejects irrelevant citations on answer-only actions' do
    resume_decision = described_class.from_payload(
      {
        decision_type: 'playbook', response_text: '', reason_code: 'side_question_unsupported', evidence_ids: [],
        playbook_control: { action: 'resume_pending_question' }
      },
      allowed_evidence_ids: [],
      evidence_status: 'insufficient_evidence',
      playbook_context: { 'pending_question' => 'What service do you need?' }
    )
    expect(resume_decision.playbook_control).to be_resume

    expect do
      described_class.from_payload(
        {
          decision_type: 'playbook', response_text: '', reason_code: 'answered', evidence_ids: ['evidence-1'],
          playbook_control: { action: 'submit_answer', answer_value: 'internet' }
        },
        allowed_evidence_ids: ['evidence-1'],
        evidence_status: 'accepted',
        playbook_context: { 'pending_question' => 'What service do you need?' }
      )
    end.to raise_error(described_class::Invalid, 'Non-grounded Playbook actions cannot cite evidence')
  end
end
