require 'rails_helper'

RSpec.describe ChatRing::Knowledge::IndexBuilder do
  around do |example|
    with_modified_env DOCSGPT_SCORE_THRESHOLD: '0.35' do
      example.run
    end
  end

  let(:account) { create(:account) }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }

  it 'builds one hidden provider index from every active website and file material' do
    first_page = website_material('https://first.example/docs', 'First website')
    second_page = website_material('https://second.example/features', 'Second website')
    file = file_material('Guide.pdf', 'Uploaded file')

    index = described_class.build!(knowledge_base)

    expect(index.documents.map(&:knowledge_material)).to contain_exactly(first_page, second_page, file)
    expect(index.documents.pluck(:provider_status).uniq).to eq(['pending'])
    expect(index.config_snapshot.fetch('source_policy_version')).to eq(ChatRing::Knowledge::SourcePolicy::VERSION)
    expect(knowledge_base.knowledge_indexes.count).to eq(1)
    expect(described_class.build!(knowledge_base)).to eq(index)
    expect(knowledge_base.knowledge_indexes.count).to eq(1)
  end

  it 'builds a replacement when the hidden retrieval configuration changes' do
    website_material('https://example.com/docs', 'Current content')
    original = described_class.build!(knowledge_base)
    make_ready(original)
    ChatRing::Knowledge::IndexActivationService.activate!(original)

    replacement = with_modified_env(DOCSGPT_SCORE_THRESHOLD: '0.40') do
      described_class.build!(knowledge_base)
    end

    expect(replacement).to be_present
    expect(replacement).not_to eq(original)
    expect(replacement.config_snapshot.dig('retrieval', 'score_threshold')).to eq(0.40)
    make_ready(replacement)
    expect(ChatRing::Knowledge::IndexActivationService.activate!(replacement)).to eq(:activated)
    expect(knowledge_base.reload.active_knowledge_index).to eq(replacement)
  end

  it 'fails closed instead of silently collapsing materials with identical content' do
    first = website_material('https://first.example/docs', 'Shared content')
    active_index = described_class.build!(knowledge_base)
    make_ready(active_index)
    ChatRing::Knowledge::IndexActivationService.activate!(active_index)

    second = website_material('https://second.example/docs', 'Other content')
    second.update!(markdown: first.markdown, content_hash: first.content_hash)

    expect { described_class.build!(knowledge_base) }
      .to raise_error(
        described_class::Error,
        'Knowledge corpus contains duplicate content: https://first.example/docs, https://second.example/docs'
      )
    expect(knowledge_base.reload.active_knowledge_index).to eq(active_index)
    expect(knowledge_base.knowledge_indexes).to contain_exactly(active_index)
  end

  it 'discards an older build instead of activating it over a newer material catalog' do
    material = website_material('https://example.com/docs', 'Original content')
    older_index = described_class.build!(knowledge_base)

    update_material(material, 'Newer content')
    newer_index = described_class.build!(knowledge_base)
    make_ready(newer_index)
    expect(ChatRing::Knowledge::IndexActivationService.activate!(newer_index)).to eq(:activated)

    make_ready(older_index)
    expect(ChatRing::Knowledge::IndexActivationService.activate!(older_index)).to eq(:stale)
    expect(knowledge_base.reload.active_knowledge_index).to eq(newer_index)
    expect(older_index.reload).to have_attributes(status: 'discarded')
  end

  it 'clears the active pointer when the user deletes the final material' do
    material = website_material('https://example.com/docs', 'Only content')
    index = described_class.build!(knowledge_base)
    make_ready(index)
    ChatRing::Knowledge::IndexActivationService.activate!(index)
    material.update!(deleted_at: Time.current)

    expect(described_class.build!(knowledge_base)).to be_nil

    expect(knowledge_base.reload.active_knowledge_index).to be_nil
    expect(index.reload.status).to eq('retired')
  end

  private

  def website_material(url, body)
    root = URI.parse(url)
    source = knowledge_base.website_sources.create!(
      root_url: "#{root.scheme}://#{root.host}/",
      status: 'available'
    )
    markdown = "# #{body}\n\n#{body} contains enough current product information for retrieval."
    knowledge_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: url,
      public_url: url,
      title: body,
      status: 'processing',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      extracted_at: Time.current
    )
  end

  def file_material(filename, body) # rubocop:disable Metrics/MethodLength
    source = knowledge_base.file_sources.create!(
      source_kind: 'pdf',
      original_filename: filename,
      content_type: 'application/pdf',
      byte_size: 100,
      raw_content_hash: Digest::SHA256.hexdigest(filename),
      parser_profile: {},
      parser_profile_digest: Digest::SHA256.hexdigest('profile')
    )
    markdown = "# #{body}\n\n#{body} contains enough current product information for retrieval."
    knowledge_base.materials.create!(
      file_source: source,
      source_kind: 'pdf',
      source_reference: source.source_reference,
      title: filename,
      status: 'processing',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      extracted_at: Time.current
    )
  end

  def update_material(material, body)
    markdown = "# #{body}\n\n#{body} contains enough current product information for retrieval."
    material.update!(
      status: 'updating',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      extracted_at: Time.current
    )
  end

  def make_ready(index)
    index.documents.each do |document|
      document.update!(
        provider_status: 'ready',
        provider_source_id: "provider-#{index.id}",
        provider_source_reference: "/inputs/#{document.provider_file_name}"
      )
    end
    index.update!(status: 'ready', ready_at: Time.current)
  end
end
