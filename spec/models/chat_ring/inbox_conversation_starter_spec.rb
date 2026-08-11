require 'rails_helper'

RSpec.describe ChatRing::InboxConversationStarter do
  let(:account) { create(:account) }
  let(:workspace) { ChatRing::Workspace.for_account!(account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_widget, account: account)) }

  it 'accepts only the bounded Website Inbox starter contract' do
    configuration = described_class.new(
      workspace: workspace,
      inbox: inbox,
      starters: [{ 'label' => 'See pricing', 'prompt' => 'What pricing plans do you offer?' }]
    )

    expect(configuration).to be_valid

    configuration.starters = [{ 'label' => 'Unsafe', 'prompt' => 'Hello', 'url' => 'https://example.com' }]
    expect(configuration).not_to be_valid
  end

  it 'rejects a non-Website or cross-account Inbox' do
    email_inbox = create(:inbox, account: account, channel: create(:channel_email, account: account))
    foreign_inbox = create(:inbox)

    email_configuration = described_class.new(workspace: workspace, inbox: email_inbox, starters: [])
    foreign_configuration = described_class.new(workspace: workspace, inbox: foreign_inbox, starters: [])

    expect(email_configuration).not_to be_valid
    expect(foreign_configuration).not_to be_valid
  end

  it 'is removed by native Inbox deletion without affecting another Inbox configuration' do
    configuration = described_class.create!(workspace: workspace, inbox: inbox, starters: [])
    other_inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    other = described_class.create!(workspace: workspace, inbox: other_inbox, starters: [])

    inbox.destroy!

    expect(described_class.exists?(configuration.id)).to be(false)
    expect(described_class.exists?(other.id)).to be(true)
  end

  it 'stores at most four starters and projects only the first two' do
    starters = Array.new(4) { |index| { 'label' => "Question #{index}", 'prompt' => "Prompt #{index}" } }
    configuration = described_class.create!(workspace: workspace, inbox: inbox, starters: starters)

    expect(ChatRing::ConversationStarters::StarterProjection.call(inbox)).to eq(starters.first(2))

    configuration.starters = starters + [{ 'label' => 'Extra', 'prompt' => 'Extra' }]
    expect(configuration).not_to be_valid
  end
end
