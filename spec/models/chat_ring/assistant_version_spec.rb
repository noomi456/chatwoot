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

  it 'pins provider and model identifiers inside the immutable version' do
    version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: knowledge_scope,
      configuration: { llm_provider: 'openai', llm_model: 'gpt-4.1-mini' }
    ).call

    expect(version).to have_attributes(llm_provider: 'openai', llm_model: 'gpt-4.1-mini')
    expect(version.update(llm_model: 'another-model')).to be(false)
  end

  it 'rejects audience and availability policies until their schemas are implemented' do
    version = described_class.new(
      assistant: assistant,
      knowledge_scope: knowledge_scope,
      version: 1,
      published_at: Time.current,
      audience_policy: { 'segment' => 'lead' },
      availability_policy: { 'always_available' => true }
    )

    expect(version).not_to be_valid
    expect(version.errors[:audience_policy]).to include('is not supported in this release')
    expect(version.errors[:availability_policy]).to include('is not supported in this release')
  end
end
