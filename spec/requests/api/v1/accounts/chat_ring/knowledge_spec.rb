require 'rails_helper'

RSpec.describe 'ChatRing Training Materials API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/knowledge" }
  let(:knowledge_base) { ChatRing::KnowledgeBase.for_account!(account) }

  it 'returns one account-level Training Materials list without an inbox parameter' do
    website_material
    file_material

    get "#{base_path}/materials", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('type')).to contain_exactly('website', 'pdf')
  end

  it 'enforces administrator management access on the server' do
    get "#{base_path}/materials", headers: agent.create_new_auth_token

    expect(response).to have_http_status(:unauthorized)
  end

  it 'prevents cross-account material identifier substitution' do
    other_account = create(:account)
    other_base = ChatRing::KnowledgeBase.for_account!(other_account)
    source = other_base.website_sources.create!(root_url: 'https://other.example/', status: 'available')
    foreign_material = create_website_material(other_base, source, 'https://other.example/')

    get "#{base_path}/materials/#{foreign_material.id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:not_found)
  end

  it 'shows extracted content without exposing private Active Storage fields' do
    material = file_material

    get "#{base_path}/materials/#{material.id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('name' => 'Guide.pdf', 'markdown' => material.markdown)
    expect(response.parsed_body.keys).not_to include('file', 'blob_key', 'storage_url')
  end

  it 'deletes the exact material immediately through one delete action' do
    material = website_material
    allow(ChatRing::Knowledge::IndexBuilder).to receive(:enqueue!)

    delete "#{base_path}/materials/#{material.id}", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:no_content)
    expect(material.reload).not_to be_active
    expect(knowledge_base.materials.active).to be_empty
  end

  it 'routes Re-run to Firecrawl for the exact selected material' do
    material = website_material
    allow(ChatRing::Knowledge::WebsiteSourceService).to receive(:rerun!).with(material).and_return(material.website_source)

    post "#{base_path}/materials/#{material.id}/rerun", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:accepted)
    expect(ChatRing::Knowledge::WebsiteSourceService).to have_received(:rerun!).with(material)
  end

  it 'routes a single webpage directly to Scrape without a website Map request' do
    allow(ChatRing::Knowledge::WebsiteSourceService).to receive(:add_webpage!).and_call_original
    allow(ChatRing::Knowledge::WebsiteExtractionJob).to receive(:perform_later)

    post "#{base_path}/webpages",
         params: { url: 'https://example.com/features' },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:accepted)
    expect(ChatRing::Knowledge::WebsiteExtractionJob).to have_received(:perform_later)
      .with(kind_of(Integer), ['https://example.com/features'], false, 'single', kind_of(String))
  end

  it 'does not expose version, publish, or rollback management routes' do
    post "#{base_path}/versions", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:not_found)
  end

  def website_material
    @website_material ||= begin
      source = knowledge_base.website_sources.create!(root_url: 'https://example.com/', status: 'available')
      create_website_material(knowledge_base, source, 'https://example.com/docs')
    end
  end

  def create_website_material(base, source, url)
    markdown = '# Website\n\nCurrent product information from the selected webpage.'
    base.materials.create!(
      website_source: source, source_kind: 'website', source_reference: url, public_url: url,
      title: 'Website', status: 'available', markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown), extracted_at: Time.current
    )
  end

  def file_material
    @file_material ||= begin
      source = knowledge_base.file_sources.create!(
        source_kind: 'pdf', original_filename: 'Guide.pdf', content_type: 'application/pdf', byte_size: 100,
        raw_content_hash: Digest::SHA256.hexdigest('Guide.pdf'), parser_profile: {},
        parser_profile_digest: Digest::SHA256.hexdigest('profile'), created_by: admin, approved_by: admin
      )
      markdown = '# Guide\n\nCurrent product documentation from the uploaded file.'
      knowledge_base.materials.create!(
        file_source: source, source_kind: 'pdf', source_reference: source.source_reference, title: 'Guide.pdf',
        status: 'available', markdown: markdown, content_hash: Digest::SHA256.hexdigest(markdown),
        extracted_at: Time.current
      )
    end
  end
end
