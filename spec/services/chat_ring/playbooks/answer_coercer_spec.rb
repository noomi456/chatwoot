require 'rails_helper'

RSpec.describe ChatRing::Playbooks::AnswerCoercer do
  it 'accepts only exact values from the immutable published choice set' do
    step = {
      kind: 'ask_choice',
      choices: [
        { label: 'Internet', value: 'internet' },
        { label: 'Television', value: 'television' }
      ]
    }

    expect(described_class.call('internet', field: { type: 'string' }, step: step)).to eq('internet')
    expect do
      described_class.call('Internet', field: { type: 'string' }, step: step)
    end.to raise_error(described_class::Invalid, 'Playbook answer must match a published choice value')
  end

  it 'normalizes bounded scalar answers without allowing the model to select fields or branches' do
    expect(described_class.call(' SALES@EXAMPLE.COM ', field: { type: 'email' }, step: { kind: 'ask_text' }))
      .to eq('sales@example.com')
    expect(described_class.call(' yes ', field: { type: 'boolean' }, step: { kind: 'ask_text' })).to be(true)
    expect(described_class.call('12.50', field: { type: 'number' }, step: { kind: 'ask_text' })).to eq('12.5')
  end

  it 'rejects malformed typed answers' do
    expect do
      described_class.call('not-an-email', field: { type: 'email' }, step: { kind: 'ask_text' })
    end.to raise_error(described_class::Invalid, 'Playbook answer is not a valid email address')

    expect do
      described_class.call('maybe', field: { type: 'boolean' }, step: { kind: 'ask_text' })
    end.to raise_error(described_class::Invalid, 'Playbook answer must be yes or no')
  end

  it 'rejects exponent notation and decimals outside the bounded server grammar' do
    expect do
      described_class.call('1e100000000', field: { type: 'number' }, step: { kind: 'ask_text' })
    end.to raise_error(described_class::Invalid, 'Playbook answer is not a bounded decimal number')

    expect do
      described_class.call('1234567890123456789', field: { type: 'number' }, step: { kind: 'ask_text' })
    end.to raise_error(described_class::Invalid, 'Playbook answer is not a bounded decimal number')
  end
end
