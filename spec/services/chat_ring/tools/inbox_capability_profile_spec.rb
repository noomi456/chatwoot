require 'rails_helper'

RSpec.describe ChatRing::Tools::InboxCapabilityProfile do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:actor) { create(:user, account: account, role: :administrator) }

  it 'selects the certified approved-link renderer for a Website Inbox' do
    inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    version = publish(inbox)

    expect(described_class.new(inbox: inbox, policy_version: version).fetch('request_appointment', 1)).to have_attributes(
      available: true,
      renderer: 'approved_link',
      fallback: 'approved_link'
    )
  end

  it 'selects the Calendly embed only when the immutable Website policy enables it' do
    inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    version = publish(inbox, website_presentation: 'calendar_embed')

    expect(described_class.new(inbox: inbox, policy_version: version).fetch('request_appointment', 1)).to have_attributes(
      available: true,
      renderer: 'calendar_embed',
      fallback: 'approved_link'
    )
  end

  it 'fails closed for a channel that has not been certified' do
    inbox = create(:inbox, :with_email, account: account)
    version = publish(inbox)
    capability = described_class.new(inbox: inbox, policy_version: version).fetch('request_appointment', 1)

    expect(capability).to have_attributes(
      available: false,
      renderer: nil,
      fallback: nil,
      reason: 'channel_not_certified'
    )
  end

  private

  def publish(inbox, website_presentation: 'approved_link')
    ChatRing::Tools::PolicyPublisher.new(
      workspace: workspace,
      inbox: inbox,
      actor: actor,
      expected_lock_version: 0,
      enabled_tools: [{ key: 'request_appointment', version: 1 }],
      tool_configurations: {
        request_appointment: {
          provider: 'calendly',
          url: 'https://calendly.com/chatring/demo',
          fallback_mode: 'approved_link',
          link_label: 'Book a meeting',
          website_presentation: website_presentation
        }
      }
    ).call
  end
end
