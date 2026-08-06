require 'rails_helper'

RSpec.describe ChatRing::Knowledge::PublicationService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:attributes) do
    {
      account: account,
      inbox: inbox,
      provider_release: '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66',
      root_url: 'https://example.com/'
    }
  end
  let(:validator) { class_double(ChatRing::Knowledge::ProviderValidator, validate!: true) }

  def mark_evaluated(version)
    version.update!(
      evaluation_status: 'passed',
      evaluated_at: Time.current,
      evaluation_report: { 'binding_digest' => version.evaluation_binding_digest }
    )
  end

  # rubocop:disable RSpec/MultipleExpectations
  it 'atomically switches the inbox pointer and preserves the previous version for rollback' do
    first = ChatRing::KnowledgeVersion.create!(**attributes, status: 'ready')
    second = ChatRing::KnowledgeVersion.create!(**attributes, status: 'ready')
    mark_evaluated(first)
    mark_evaluated(second)

    described_class.publish!(first, validator: validator)
    publication = described_class.publish!(second, validator: validator)

    expect(publication.reload.knowledge_version).to eq(second)
    expect(publication.previous_knowledge_version).to eq(first)
    expect(first.reload.status).to eq('retired')
    expect(second.reload.status).to eq('published')

    rolled_back = described_class.rollback!(account: account, inbox: inbox, validator: validator)
    expect(rolled_back.knowledge_version).to eq(first)
    expect(first.reload.status).to eq('published')
    expect(second.reload.status).to eq('retired')
    expect(rolled_back.previous_knowledge_version).to be_nil
    expect(ChatRing::KnowledgePublicationEvent.order(:id).pluck(:action)).to eq(%w[publish publish rollback])
  end
  # rubocop:enable RSpec/MultipleExpectations

  it 'refuses to publish a partial or failed version' do
    version = ChatRing::KnowledgeVersion.create!(**attributes, status: 'ingesting')

    expect { described_class.publish!(version, validator: validator) }.to raise_error(
      described_class::Error,
      /not eligible/
    )
  end

  it 'refuses to publish a ready version without a current passed evaluation' do
    version = ChatRing::KnowledgeVersion.create!(**attributes, status: 'ready')

    expect { described_class.publish!(version, validator: validator) }.to raise_error(
      described_class::Error,
      /has not passed the current retrieval evaluation/
    )
  end
end
