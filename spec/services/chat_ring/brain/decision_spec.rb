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
end
