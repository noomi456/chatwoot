require 'rails_helper'

RSpec.describe ChatRing::Knowledge::AbandonmentService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  def ready_version(evaluation_status: 'failed', evaluated_at: 8.days.ago)
    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      evaluation_status: evaluation_status,
      evaluated_at: evaluated_at,
      provider_release: 'provider-release',
      root_url: 'https://example.com/'
    )
    version.documents.create!(
      source_url: 'https://example.com/',
      markdown: '# Example',
      content_hash: 'a' * 64,
      provider_file_name: 'example.md',
      provider_source_id: 'source-1',
      provider_status: 'ready'
    )
    version.update!(status: 'ready')
    version
  end

  it 'marks an unpublished ready version abandoned and schedules retained cleanup' do
    version = ready_version

    expect do
      described_class.abandon!(version, reason: 'administrator rejected candidate')
    end.to have_enqueued_job(ChatRing::Knowledge::ProviderCleanupJob)

    expect(version.reload).to have_attributes(
      status: 'abandoned',
      abandon_reason: 'administrator rejected candidate'
    )
    expect(version.abandoned_at).to be_present
    expect(version.provider_cleanup).to be_present
    expect(version.provider_cleanup.eligible_at).to be > Time.current
  end

  it 'never abandons a version retained by a publication pointer' do
    version = ready_version
    current = ready_version(evaluation_status: 'passed')
    current.update!(status: 'published')
    ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: current,
      previous_knowledge_version: version,
      published_at: Time.current
    )

    expect do
      described_class.abandon!(version, reason: 'unsafe')
    end.to raise_error(described_class::Error, /retained by a publication pointer/)
    expect(version.reload.status).to eq('ready')
  end

  it 'automatically abandons only evaluation failures beyond the grace period' do
    overdue = ready_version
    recent = ready_version(evaluated_at: 1.day.ago)
    passed = ready_version(evaluation_status: 'passed')

    abandoned = described_class.abandon_overdue_evaluation_failures!

    expect(abandoned.map(&:id)).to contain_exactly(overdue.id)
    expect(overdue.reload.status).to eq('abandoned')
    expect(overdue.provider_cleanup.eligible_at).to be <= Time.current
    expect(recent.reload.status).to eq('ready')
    expect(passed.reload.status).to eq('ready')
  end

  it 'rechecks the failed evaluation under lock before automatic abandonment' do
    version = ready_version
    allow(described_class).to receive(:abandon!).and_wrap_original do |method, candidate, **kwargs|
      candidate.update!(evaluation_status: 'passed', evaluated_at: Time.current)
      method.call(candidate, **kwargs)
    end

    expect(described_class.abandon_overdue_evaluation_failures!).to be_empty
    expect(version.reload).to have_attributes(status: 'ready', evaluation_status: 'passed')
    expect(version.provider_cleanup).to be_nil
  end
end
