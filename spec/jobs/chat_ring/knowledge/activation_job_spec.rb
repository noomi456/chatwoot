require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ActivationJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ready',
      root_url: 'https://example.com/',
      provider_release: 'provider-release',
      config_snapshot: { 'publish_on_ready' => true }
    )
  end

  it 'activates a ready source-managed version through the verified publication path' do
    allow(ChatRing::Knowledge::PublicationService).to receive(:publish_verified!)

    described_class.perform_now(version.id)

    expect(ChatRing::Knowledge::PublicationService).to have_received(:publish_verified!).with(version)
  end

  it 'does not activate an ordinary ready version' do
    ordinary = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ready',
      root_url: 'https://ordinary.example.com/',
      provider_release: 'provider-release',
      config_snapshot: {}
    )
    allow(ChatRing::Knowledge::PublicationService).to receive(:publish_verified!)

    described_class.perform_now(ordinary.id)

    expect(ChatRing::Knowledge::PublicationService).not_to have_received(:publish_verified!)
  end
end
