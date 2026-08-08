require 'rails_helper'

RSpec.describe ChatRing::Knowledge::Retriever do
  let(:account) { create(:account) }
  let(:first_inbox) { create(:inbox, account: account) }
  let(:second_inbox) { create(:inbox, account: account) }
  let(:provider) { instance_double(ChatRing::Knowledge::DocsGptProvider) }

  it 'uses the same account Knowledge Base from two different inbox contexts' do
    index, = active_index
    allow(described_class).to receive(:provider).with(index).and_return(provider)
    evidence_set = ChatRing::Knowledge::EvidenceSet.new(
      knowledge_index_id: index.id.to_s,
      provider: 'docs_gpt',
      provider_release: index.provider_release,
      query: 'Question',
      status: 'accepted',
      error_code: nil,
      latency_ms: 1,
      retrieval_strategy: 'classic_cosine',
      retrieval_configuration: {},
      items: [].freeze
    )
    allow(provider).to receive(:retrieve).and_return(evidence_set)

    expect(described_class.retrieve(inbox: first_inbox, query: 'Question')).to have_attributes(status: 'insufficient_evidence')
    expect(described_class.retrieve(inbox: second_inbox, query: 'Question')).to have_attributes(status: 'insufficient_evidence')
    expect(provider).to have_received(:retrieve).twice
  end

  it 'does not expose another account Knowledge Base' do
    active_index
    other_account = create(:account)
    other_inbox = create(:inbox, account: other_account)

    result = described_class.retrieve(inbox: other_inbox, query: 'Question')

    expect(result).to have_attributes(status: 'insufficient_evidence', items: [])
  end

  it 'filters a user-deleted material immediately even before the old provider index is cleaned' do
    index, material = active_index
    expect(described_class.source_manifest(index).values.first.fetch('active')).to be(true)

    material.update!(deleted_at: Time.current)

    expect(described_class.source_manifest(index).values.first.fetch('active')).to be(false)
  end

  it 'returns typed zero evidence when the user deletes the final material' do
    _index, material = active_index
    material.update!(deleted_at: Time.current)

    result = described_class.retrieve(inbox: first_inbox, query: 'Question')

    expect(result).to have_attributes(status: 'insufficient_evidence', items: [])
  end

  it 'retrieves from the turn-pinned retired index after a newer active pointer is selected' do
    index, = active_index
    provider = instance_double(ChatRing::Knowledge::DocsGptProvider)
    allow(described_class).to receive(:provider).with(index).and_return(provider)
    allow(provider).to receive(:retrieve).and_return(
      ChatRing::Knowledge::EvidenceSet.new(
        knowledge_index_id: index.id.to_s, provider: 'docs_gpt', provider_release: index.provider_release,
        query: 'Question', status: 'accepted', error_code: nil, latency_ms: 1,
        retrieval_strategy: 'classic_cosine', retrieval_configuration: {}, items: [].freeze
      )
    )
    index.update!(status: 'retired')

    result = described_class.retrieve(inbox: first_inbox, query: 'Question', knowledge_index_id: index.id)

    expect(result.status).to eq('insufficient_evidence')
    expect(provider).to have_received(:retrieve)
  end

  def active_index # rubocop:disable Metrics/MethodLength
    knowledge_base = ChatRing::KnowledgeBase.for_account!(account)
    source = knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available')
    markdown = '# Example\n\nShared business knowledge for every Assistant in this account.'
    material = knowledge_base.materials.create!(
      website_source: source, source_kind: 'website', source_reference: 'https://example.com/',
      public_url: 'https://example.com/', title: 'Example', status: 'available', markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown), extracted_at: Time.current
    )
    index = knowledge_base.knowledge_indexes.create!(
      workspace: knowledge_base.workspace, status: 'building', provider_release: 'provider-release',
      mapped_manifest: [], manifest_digest: Digest::SHA256.hexdigest('manifest')
    )
    index.documents.create!(
      knowledge_material: material, source_kind: 'website', source_reference: material.source_reference,
      source_url: material.public_url, public_url: material.public_url, title: material.title,
      markdown: markdown, content_hash: material.content_hash, provider_file_name: 'example.md',
      provider_source_id: 'source-1', provider_source_reference: '/inputs/example.md', provider_status: 'ready',
      metadata: {
        'authority_class' => 'product_documentation', 'headings' => [], 'cta_candidates' => [],
        'material_key' => material.material_key
      }
    )
    index.update!(status: 'active', activated_at: Time.current)
    knowledge_base.update!(active_knowledge_index: index)
    [index, material]
  end
end
