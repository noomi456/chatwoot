require 'rails_helper'

RSpec.describe ChatRing::Knowledge::MaterialService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }
  let(:source) do
    knowledge_base.file_sources.create!(
      source_kind: 'pdf', original_filename: 'Guide.pdf', content_type: 'application/pdf', byte_size: 100,
      raw_content_hash: Digest::SHA256.hexdigest('Guide.pdf'), parser_profile: {},
      parser_profile_digest: Digest::SHA256.hexdigest('profile')
    )
  end
  let(:material) do
    markdown = '# Guide\n\nCurrent product documentation that is available to the AI.'
    knowledge_base.materials.create!(
      file_source: source, source_kind: 'pdf', source_reference: source.source_reference,
      title: 'Guide.pdf', status: 'available', markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown), extracted_at: Time.current
    )
  end

  it 'tombstones the selected row immediately and queues only replacement indexing and file cleanup' do
    source.file.attach(
      io: StringIO.new('%PDF-1.4 knowledge'), filename: 'Guide.pdf', content_type: 'application/pdf'
    )
    material

    index_job = have_enqueued_job(ChatRing::Knowledge::IndexBuildJob).with(knowledge_base.id)
    purge_job = have_enqueued_job(ChatRing::Knowledge::FileAttachmentPurgeJob).with(source.id, source.file.blob_id)

    expect do
      described_class.delete!(material)
    end.to index_job.and(purge_job)

    expect(material.reload).to have_attributes(deleted_at: be_present, markdown: nil, content_hash: nil)
    expect(source.reload).to have_attributes(status: 'deleted', markdown: nil, content_hash: nil)
  end
end
