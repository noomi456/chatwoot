require 'rails_helper'

RSpec.describe ChatRing::MicrositeCleanupJob do
  it 'deletes only expired generated artifacts' do
    expired_context = ChatRingPlaybookSpecSupport.build
    available_context = ChatRingPlaybookSpecSupport.build
    expired = create_artifact(expired_context.fetch(:turn), 1.minute.ago)
    available = create_artifact(available_context.fetch(:turn), 1.day.from_now)

    described_class.perform_now

    expect(ChatRing::MicrositeArtifact.find_by(id: expired.id)).to be_nil
    expect(ChatRing::MicrositeArtifact.find_by(id: available.id)).to eq(available)
  end

  private

  def create_artifact(turn, expires_at)
    turn.evidence.create!(
      position: 0,
      evidence_id: 'evidence-1',
      source_kind: 'website',
      source_reference: 'facts',
      source_title: 'Facts',
      excerpt: 'Verified content',
      source_content_hash: Digest::SHA256.hexdigest("verified content #{turn.id}"),
      rank: 0,
      score: 1,
      metadata: {}
    )
    ChatRing::MicrositeArtifact.create!(
      workspace: turn.workspace,
      ai_turn: turn,
      content: {
        'title' => 'Generated page',
        'sections' => [{ 'type' => 'content', 'title' => 'Facts', 'body' => 'Verified content', 'items' => [] }]
      },
      source_evidence_ids: ['evidence-1'],
      expires_at: expires_at
    )
  end
end
