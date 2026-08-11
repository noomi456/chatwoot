require 'rails_helper'

RSpec.describe ChatRing::InboxEngagement do
  let(:account) { create(:account) }
  let(:workspace) { ChatRing::Workspace.for_account!(account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }

  it 'accepts only the bounded Website Inbox starter contract' do
    engagement = described_class.new(
      workspace: workspace,
      inbox: inbox,
      starters: [{ 'label' => 'See pricing', 'prompt' => 'What pricing plans do you offer?' }]
    )

    expect(engagement).to be_valid

    engagement.starters = [{ 'label' => 'Unsafe', 'prompt' => 'Hello', 'url' => 'https://example.com' }]
    expect(engagement).not_to be_valid
  end

  it 'rejects a non-Website or cross-account Inbox' do
    email_inbox = create(:inbox, account: account, channel: create(:channel_email, account: account))
    foreign_inbox = create(:inbox)

    email_engagement = described_class.new(workspace: workspace, inbox: email_inbox, starters: [])
    foreign_engagement = described_class.new(workspace: workspace, inbox: foreign_inbox, starters: [])

    expect(email_engagement).not_to be_valid
    expect(foreign_engagement).not_to be_valid
  end

  it 'is removed by native Inbox deletion without affecting another Inbox configuration' do
    engagement = described_class.create!(workspace: workspace, inbox: inbox, starters: [])
    other_inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    other = described_class.create!(workspace: workspace, inbox: other_inbox, starters: [])

    inbox.destroy!

    expect(described_class.exists?(engagement.id)).to be(false)
    expect(described_class.exists?(other.id)).to be(true)
  end
end
