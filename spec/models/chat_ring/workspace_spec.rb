require 'rails_helper'

RSpec.describe ChatRing::Workspace do
  it 'provisions exactly one shared Knowledge Base and business-wide scope for a Chatwoot Account' do
    account = create(:account)

    expect(account.reload.chat_ring_workspace).to have_attributes(chatwoot_account_id: account.id)
    expect(account.chat_ring_workspace.knowledge_base).to be_present
    expect(account.chat_ring_workspace.knowledge_scopes.where(business_wide: true).count).to eq(1)
  end

  it 'rejects a material rule that crosses Workspace ownership' do
    first_workspace = ChatRing::Workspace.for_account!(create(:account))
    second_base = ChatRing::KnowledgeBase.for_account!(create(:account))
    source = second_base.website_sources.create!(root_url: 'https://other.example/', status: 'available')
    material = second_base.materials.create!(
      website_source: source,
      source_kind: 'website',
      source_reference: 'https://other.example/',
      public_url: 'https://other.example/',
      status: 'failed'
    )

    rule = first_workspace.knowledge_scopes.find_by!(business_wide: true).material_rules.new(
      knowledge_material: material,
      access: 'allow'
    )

    expect(rule).not_to be_valid
    expect(rule.errors[:knowledge_material]).to include('belongs to another Workspace')
  end
end
