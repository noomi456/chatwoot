require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ActivationJob do
  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:index) do
    knowledge_base.knowledge_indexes.create!(
      workspace: knowledge_base.workspace,
      status: 'ready',
      provider: 'docs_gpt',
      provider_release: 'provider-release',
      mapped_manifest: [],
      manifest_digest: Digest::SHA256.hexdigest([].to_json),
      config_snapshot: {}
    )
  end

  it 'atomically activates a ready hidden provider index' do
    allow(ChatRing::Knowledge::IndexActivationService).to receive(:activate!)

    described_class.perform_now(index.id)

    expect(ChatRing::Knowledge::IndexActivationService).to have_received(:activate!).with(index)
  end
end
