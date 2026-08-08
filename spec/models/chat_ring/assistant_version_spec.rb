require 'rails_helper'

RSpec.describe ChatRing::AssistantVersion do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:knowledge_scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }

  it 'is immutable after publication' do
    version = described_class.create!(
      assistant: assistant,
      knowledge_scope: knowledge_scope,
      version: 1,
      published_at: Time.current,
      instructions: 'Answer from approved evidence.'
    )

    expect(version.update(instructions: 'Changed later')).to be(false)
    expect(version.errors[:base]).to include('published Assistant version is immutable')
  end

  it 'requires its Knowledge Scope to belong to the Assistant Workspace' do
    other_scope = create(:account).chat_ring_workspace.knowledge_scopes.find_by!(business_wide: true)
    version = described_class.new(
      assistant: assistant,
      knowledge_scope: other_scope,
      version: 1,
      published_at: Time.current
    )

    expect(version).not_to be_valid
    expect(version.errors[:knowledge_scope]).to include('must belong to the Assistant Workspace')
  end
end
