require 'rails_helper'

RSpec.describe ChatRing::Tools::Request do
  it 'removes nullable structured-output arguments before Tool validation' do
    request = described_class.from_payload(
      'key' => 'request_appointment',
      'version' => 1,
      'arguments' => { 'requested_time_window' => nil, 'reason_code' => nil }
    )

    expect(request.arguments).to eq({})
  end
end
