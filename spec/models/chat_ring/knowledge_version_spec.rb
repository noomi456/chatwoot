require 'rails_helper'

RSpec.describe ChatRing::KnowledgeVersion do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    described_class.create!(
      account: account,
      inbox: inbox,
      status: 'ready',
      provider_release: 'provider-release',
      root_url: 'https://example.com/',
      mapped_manifest: [{ 'url' => 'https://example.com/', 'included' => true }],
      manifest_digest: 'a' * 64,
      config_snapshot: { 'retrieval' => { 'score_threshold' => 0.62 } }
    )
  end

  it 'rejects mutation of a completed build snapshot' do
    expect(version.update(root_url: 'https://other.example/')).to be(false)
    expect(version.errors[:base]).to include('completed knowledge-version build snapshot is immutable')
  end

  it 'allows publication and evaluation lifecycle fields to change' do
    expect(
      version.update(
        status: 'published',
        evaluation_status: 'passed',
        evaluation_report: { 'binding_digest' => version.evaluation_binding_digest },
        evaluated_at: Time.current,
        published_at: Time.current
      )
    ).to be(true)
  end
end
