require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileSourcePurgeService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:actor) { create(:user) }

  it 'purges only an explicitly disabled source that is absent from the published version' do
    source = create_disabled_source

    described_class.call(source)

    expect(ChatRing::KnowledgeFileSource.exists?(source.id)).to be(false)
    expect(ActiveStorage::Attachment.where(record_type: 'ChatRing::KnowledgeFileSource', record_id: source.id)).to be_empty
  end

  it 'refuses to purge a source still used by the published knowledge version' do
    source = create_disabled_source
    version = ChatRing::KnowledgeVersion.create!(account: account, inbox: inbox, status: 'ingesting', provider_release: 'release')
    markdown = '# Published private guide'
    version.documents.create!(
      file_source: source,
      source_kind: 'pdf',
      source_reference: source.source_reference,
      title: source.original_filename,
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      provider_file_name: 'guide.md',
      provider_status: 'ready'
    )
    version.update!(status: 'published', published_at: Time.current)
    ChatRing::KnowledgePublication.create!(account: account, inbox: inbox, knowledge_version: version, published_at: Time.current)

    expect { described_class.call(source) }.to raise_error(
      described_class::Error,
      /Publish a knowledge version without this file/
    )
    expect(source.reload.file).to be_attached
  end

  def create_disabled_source
    source = ChatRing::KnowledgeFileSource.create!(
      account: account,
      inbox: inbox,
      status: 'uploaded',
      source_kind: 'pdf',
      original_filename: 'Guide.pdf',
      content_type: 'application/pdf',
      byte_size: 100,
      raw_content_hash: Digest::SHA256.hexdigest('Guide.pdf'),
      parser_profile: { 'formats' => ['markdown'] },
      parser_profile_digest: Digest::SHA256.hexdigest('profile'),
      created_by: actor
    )
    source.file.attach(io: File.open(Rails.root.join('spec/assets/sample.pdf'), 'rb'), filename: 'Guide.pdf', content_type: 'application/pdf')
    source.update!(status: 'disabled', disabled_at: Time.current)
    source
  end
end
