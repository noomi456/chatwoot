require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderValidator do
  around do |example|
    with_modified_env(
      DOCSGPT_BASE_URL: 'http://docsgpt.internal:7091',
      DOCSGPT_JWT_SECRET: 'jwt-secret',
      DOCSGPT_INTERNAL_KEY: 'internal-key',
      DOCSGPT_SERVICE_SECRET: 'service-secret'
    ) { example.run }
  end

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:version) do
    ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
  end
  let!(:document) do
    version.documents.create!(
      source_url: 'https://example.com/',
      markdown: '# Example',
      content_hash: Digest::SHA256.hexdigest('# Example'),
      provider_file_name: 'example.md',
      provider_source_id: 'source-1',
      provider_source_reference: '/inputs/example.md',
      provider_status: 'ready'
    )
  end
  let(:client) { instance_double(ChatRing::Knowledge::DocsGptClient) }

  before do
    version.update!(status: 'ready')
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)
  end

  it 'rejects a provider index containing a source outside the immutable manifest' do
    allow(client).to receive(:chunks).with('source-1').and_return(
      [
        { 'metadata' => { 'source' => document.provider_source_reference } },
        { 'metadata' => { 'source' => '/inputs/unexpected.md' } }
      ]
    )

    expect { described_class.validate!(version) }.to raise_error(
      described_class::Error,
      /outside the knowledge-version manifest/
    )
  end

  it 'rejects an untraceable provider chunk without a source reference' do
    allow(client).to receive(:chunks).with('source-1').and_return(
      [{ 'metadata' => { 'source' => nil } }]
    )

    expect { described_class.validate!(version) }.to raise_error(
      described_class::Error,
      /chunks without a source reference/
    )
  end
end
