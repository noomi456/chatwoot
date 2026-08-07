require 'rails_helper'

RSpec.describe ChatRing::Knowledge::FileSourceReconciler do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:actor) { create(:user) }

  it 'marks only hour-old parsing records indeterminate for explicit retry' do
    now = Time.zone.parse('2026-08-07 12:00:00')
    stale = create_source(parse_started_at: now - 61.minutes)
    current = create_source(parse_started_at: now - 59.minutes)

    described_class.call(now: now)

    expect(stale.reload).to have_attributes(status: 'parse_indeterminate', failure_code: 'stale_parse_reconciled')
    expect(current.reload).to have_attributes(status: 'parsing')
  end

  it 'recovers an uploaded source whose parse job was lost and fails an orphan without an attachment' do
    now = Time.zone.parse('2026-08-07 12:00:00')
    recoverable = create_uploaded_source(created_at: now - 11.minutes, attached: true)
    orphaned = create_uploaded_source(created_at: now - 11.minutes, attached: false)
    current = create_uploaded_source(created_at: now - 9.minutes, attached: true)
    allow(ChatRing::Knowledge::FileParseJob).to receive(:perform_later)

    described_class.call(now: now)

    expect(ChatRing::Knowledge::FileParseJob).to have_received(:perform_later).with(recoverable.id).once
    expect(ChatRing::Knowledge::FileParseJob).not_to have_received(:perform_later).with(current.id)
    expect(orphaned.reload).to have_attributes(status: 'failed', failure_code: 'attachment_missing')
  end

  def create_source(parse_started_at:)
    ChatRing::KnowledgeFileSource.create!(
      **source_attributes,
      status: 'parsing',
      parse_started_at: parse_started_at
    )
  end

  def create_uploaded_source(created_at:, attached:)
    source = ChatRing::KnowledgeFileSource.create!(
      **source_attributes,
      created_at: created_at,
      updated_at: created_at
    )
    if attached
      path = Rails.root.join('spec/assets/sample.pdf')
      source.file.attach(io: File.open(path, 'rb'), filename: source.original_filename, content_type: source.content_type)
    end
    source
  end

  def source_attributes
    {
      account: account,
      inbox: inbox,
      source_kind: 'pdf',
      original_filename: "Source-#{SecureRandom.hex(4)}.pdf",
      content_type: 'application/pdf',
      byte_size: 100,
      raw_content_hash: SecureRandom.hex(32),
      parser_profile: { 'formats' => ['markdown'] },
      parser_profile_digest: SecureRandom.hex(32),
      created_by: actor,
      approved_by: actor
    }
  end
end
