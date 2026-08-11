require 'rails_helper'

RSpec.describe ChatRing::Tools::Registry do
  it 'defines appointment as a semantic Tool without a model-controlled URL' do
    definition = described_class.fetch('request_appointment', 1)

    expect(definition.side_effect_class).to eq('customer_visible')
    expect(definition.authorization_policy).to eq('inbox_tool_policy')
    expect(definition.input_schema['properties']).not_to have_key('url')
    expect(definition.renderer_families).to contain_exactly('approved_link', 'calendar_embed')
  end

  it 'rejects unknown Tool versions' do
    expect { described_class.fetch('request_appointment', 2) }.to raise_error(KeyError)
  end
end
