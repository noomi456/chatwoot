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

  it 'rejects a factual reply without accepted evidence' do
    expect do
      described_class.from_payload(
        { decision_type: 'reply', response_text: 'Unsupported claim', reason_code: 'answered', evidence_ids: [] },
        allowed_evidence_ids: [],
        evidence_status: 'insufficient_evidence'
      )
    end.to raise_error(described_class::Invalid, 'Grounded replies require accepted evidence')
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
end
