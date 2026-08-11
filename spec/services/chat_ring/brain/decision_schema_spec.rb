require 'rails_helper'

RSpec.describe ChatRing::Brain::DecisionSchema do
  it 'uses OpenAI strict-schema-compatible nullable fields' do
    schema = described_class.new.to_json_schema.deep_stringify_keys.fetch('schema')

    expect(schema.fetch('required').map(&:to_s)).to contain_exactly(
      'decision_type', 'response_text', 'reason_code', 'evidence_ids', 'suggested_questions',
      'response_options', 'microsite_section_types', 'tool_request', 'playbook_control'
    )
    expect(schema.dig('properties', 'tool_request', 'anyOf').last).to eq('type' => 'null')
    expect(schema.dig('properties', 'playbook_control', 'anyOf').last).to eq('type' => 'null')

    tool = schema.dig('properties', 'tool_request', 'anyOf').first
    expect(tool.fetch('required').map(&:to_s)).to contain_exactly('key', 'version', 'arguments')
    expect(tool.dig('properties', 'arguments', 'required').map(&:to_s)).to contain_exactly(
      'requested_time_window', 'reason_code'
    )

    playbook = schema.dig('properties', 'playbook_control', 'anyOf').first
    expect(playbook.fetch('required').map(&:to_s)).to contain_exactly('action', 'answer_value')
  end
end
