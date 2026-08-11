require 'rails_helper'

RSpec.describe 'ChatRing microsite shares', type: :request do
  let(:artifact) do
    context = ChatRingPlaybookSpecSupport.build
    turn = context.fetch(:turn)
    create_evidence(turn)
    ChatRing::MicrositeArtifact.create!(
      workspace: turn.workspace,
      ai_turn: turn,
      content: {
        'title' => 'Verified Internet Guide',
        'summary' => 'A grounded summary.',
        'sections' => [
          {
            'type' => 'content',
            'title' => 'Internet plans',
            'body' => '<script>alert(1)</script>Verified facts only.',
            'items' => []
          }
        ]
      },
      source_evidence_ids: ['evidence-1'],
      expires_at: 1.day.from_now
    )
  end

  def create_evidence(turn)
    turn.evidence.create!(
      position: 0,
      evidence_id: 'evidence-1',
      source_kind: 'website',
      source_reference: 'pricing',
      source_title: 'Pricing',
      excerpt: 'Verified content',
      source_content_hash: Digest::SHA256.hexdigest('verified content'),
      rank: 0,
      score: 1,
      metadata: {}
    )
  end

  it 'renders an unindexed escaped share page while the artifact is available' do
    get "/s/#{artifact.public_token}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Verified Internet Guide', 'Verified facts only.', 'noindex,nofollow')
    expect(response.body).not_to include('<script>alert(1)</script>')
  end

  it 'returns not found after expiry' do
    public_token = artifact.public_token
    travel_to(2.days.from_now) do
      get "/s/#{public_token}"
    end

    expect(response).to have_http_status(:not_found)
  end
end
