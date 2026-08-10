require 'rails_helper'

RSpec.describe ChatRing::Tools::ApprovedPublicUrl do
  it 'normalizes an approved provider URL and removes fragments' do
    expect(described_class.normalize!('https://cal.com/chatring/demo#booking', provider: 'calcom')).to eq(
      'https://cal.com/chatring/demo'
    )
  end

  it 'rejects unsafe and provider-mismatched URLs' do
    expect { described_class.normalize!('http://cal.com/chatring', provider: 'calcom') }
      .to raise_error(described_class::Invalid, /HTTPS/)
    expect { described_class.normalize!('https://127.0.0.1/calendar', provider: 'custom_link') }
      .to raise_error(described_class::Invalid, /public hostname/)
    expect { described_class.normalize!('https://router/calendar', provider: 'custom_link') }
      .to raise_error(described_class::Invalid, /public hostname/)
    expect { described_class.normalize!('https://[::ffff:127.0.0.1]/calendar', provider: 'custom_link') }
      .to raise_error(described_class::Invalid, /public hostname/)
    expect { described_class.normalize!('https://example.com/calendar', provider: 'calendly') }
      .to raise_error(described_class::Invalid, /does not match/)
  end

  it 'accepts a custom link only on a public fully qualified hostname' do
    expect(described_class.normalize!('https://Bookings.Example.COM./calendar', provider: 'custom_link')).to eq(
      'https://bookings.example.com/calendar'
    )
  end
end
