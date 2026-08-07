require 'rails_helper'

RSpec.describe 'ChatRing Knowledge management API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:base_path) { "/api/v1/accounts/#{account.id}/chat_ring/knowledge" }

  around do |example|
    with_modified_env(DOCSGPT_SCORE_THRESHOLD: '0.62') { example.run }
  end

  it 'allows an administrator to list only the selected inbox file sources' do
    other_inbox = create(:inbox, account: account)
    create_source(inbox: inbox, filename: 'Visible.pdf')
    create_source(inbox: other_inbox, filename: 'Hidden.pdf')

    get "#{base_path}/file_sources",
        params: { inbox_id: inbox.id },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.pluck('filename')).to eq(['Visible.pdf'])
  end

  it 'enforces administrator access on the server' do
    get "#{base_path}/file_sources",
        params: { inbox_id: inbox.id },
        headers: agent.create_new_auth_token

    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not accept an inbox from another account through identifier substitution' do
    other_account = create(:account)
    other_inbox = create(:inbox, account: other_account)

    get "#{base_path}/file_sources",
        params: { inbox_id: other_inbox.id },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:not_found)
  end

  it 'builds additively from the published website version and every enabled ready file by default' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    published = create_website_version
    ChatRing::KnowledgePublication.create!(
      account: account,
      inbox: inbox,
      knowledge_version: published,
      published_at: Time.current
    )
    file_source = create_source(inbox: inbox, filename: 'Additional.pdf', ready: true)

    post "#{base_path}/versions",
         params: { inbox_id: inbox.id },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:accepted)
    created = ChatRing::KnowledgeVersion.find(response.parsed_body.fetch('id'))
    expect(created.documents.pluck(:source_reference)).to contain_exactly(
      'https://example.com/docs',
      file_source.source_reference
    )
    expect(created.config_snapshot).to include('publish_on_ready' => true)
    expect(ChatRing::Knowledge::SyncJob).to have_received(:perform_later).with(created.id)
  end

  it 'removes one webpage by building a replacement while preserving ready files' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    base = create_website_version(additional_page: true)
    keep = base.documents.find_by!(source_reference: 'https://example.com/keep')
    file_source = create_source(inbox: inbox, filename: 'Keep.pdf', ready: true)
    removed = base.documents.find_by!(source_reference: 'https://example.com/docs')

    delete "#{base_path}/website_materials/#{removed.id}",
           params: { inbox_id: inbox.id, version_id: base.id },
           headers: admin.create_new_auth_token

    expect(response).to have_http_status(:accepted)
    created = ChatRing::KnowledgeVersion.find(response.parsed_body.fetch('id'))
    expect(created.documents.pluck(:source_reference)).to contain_exactly(keep.source_reference, file_source.source_reference)
    expect(created.mapped_manifest.find { |entry| entry['url'] == removed.source_reference }).to include(
      'included' => false,
      'exclusion_reason' => 'administrator_removed'
    )
  end

  it 'rejects attempts to omit enabled files from a knowledge build' do
    create_website_version

    post "#{base_path}/versions",
         params: { inbox_id: inbox.id, file_source_ids: [] },
         headers: admin.create_new_auth_token

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch('error')).to include('disable a source explicitly')
  end

  it 'shows extracted Markdown to an administrator without exposing private storage identifiers' do
    source = create_source(inbox: inbox, filename: 'Private.pdf', ready: true)

    get "#{base_path}/file_sources/#{source.id}",
        params: { inbox_id: inbox.id },
        headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'filename' => 'Private.pdf',
      'source_reference' => source.source_reference,
      'markdown' => source.markdown
    )
    expect(response.parsed_body.keys).not_to include('file', 'blob_key', 'storage_url')
  end

  it 'keeps extracted Markdown out of the list response' do
    create_source(inbox: inbox, filename: 'Private.pdf', ready: true)

    get "#{base_path}/file_sources", params: { inbox_id: inbox.id }, headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.first).not_to have_key('markdown')
  end

  it 'requires disablement before explicitly purging an unused private upload' do
    source = create_source(inbox: inbox, filename: 'Purge.pdf', ready: true)

    delete "#{base_path}/file_sources/#{source.id}", params: { inbox_id: inbox.id }, headers: admin.create_new_auth_token
    delete "#{base_path}/file_sources/#{source.id}/purge", params: { inbox_id: inbox.id }, headers: admin.create_new_auth_token

    expect(response).to have_http_status(:no_content)
    expect(ChatRing::KnowledgeFileSource.exists?(source.id)).to be(false)
  end

  it 'removes a deleted file from the next published material set' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    base = create_website_version
    file_source = create_source(inbox: inbox, filename: 'Remove.pdf', ready: true)
    combined = ChatRing::Knowledge::VersionComposer.compose!(
      account: account,
      inbox: inbox,
      base_version: base,
      file_sources: [file_source]
    )
    combined.update!(status: 'published', ready_at: Time.current, published_at: Time.current)
    ChatRing::KnowledgePublication.create!(account: account, inbox: inbox, knowledge_version: combined, published_at: Time.current)

    delete "#{base_path}/file_sources/#{file_source.id}",
           params: { inbox_id: inbox.id },
           headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    replacement = ChatRing::KnowledgeVersion.find(response.parsed_body.fetch('knowledge_version_id'))
    expect(replacement.documents.pluck(:source_kind)).to contain_exactly('website')
    expect(file_source.reload.status).to eq('disabled')
  end

  it 'clears the publication when the final file is deleted' do
    allow(ChatRing::Knowledge::SyncJob).to receive(:perform_later)
    file_source = create_source(inbox: inbox, filename: 'Last.pdf', ready: true)
    current = ChatRing::Knowledge::VersionComposer.compose!(account: account, inbox: inbox, file_sources: [file_source])
    current.update!(status: 'published', ready_at: Time.current, published_at: Time.current)
    ChatRing::KnowledgePublication.create!(account: account, inbox: inbox, knowledge_version: current, published_at: Time.current)

    delete "#{base_path}/file_sources/#{file_source.id}",
           params: { inbox_id: inbox.id },
           headers: admin.create_new_auth_token

    expect(response).to have_http_status(:ok)
    empty_version = ChatRing::KnowledgeVersion.find(response.parsed_body.fetch('knowledge_version_id'))
    expect(empty_version).to have_attributes(status: 'ready')
    expect(empty_version.documents).to be_empty
    expect(ChatRing::KnowledgePublication.find_by(account: account, inbox: inbox)).to be_nil
  end

  def create_source(inbox:, filename:, ready: false) # rubocop:disable Metrics/MethodLength
    source = ChatRing::KnowledgeFileSource.create!(
      account: account,
      inbox: inbox,
      source_kind: 'pdf',
      original_filename: filename,
      content_type: 'application/pdf',
      byte_size: 100,
      raw_content_hash: Digest::SHA256.hexdigest(filename),
      parser_profile: { 'formats' => ['markdown'] },
      parser_profile_digest: Digest::SHA256.hexdigest('profile'),
      created_by: admin,
      approved_by: admin
    )
    return source unless ready

    sample = Rails.root.join('spec/assets/sample.pdf')
    markdown = "# Additional guide\n\nExisting materials stay available when this file is added."
    source.file.attach(io: File.open(sample, 'rb'), filename: filename, content_type: 'application/pdf')
    source.update!(
      status: 'ready',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      parsed_at: Time.current
    )
    source
  end

  def create_website_version(additional_page: false) # rubocop:disable Metrics/MethodLength
    manifest = [{ 'url' => 'https://example.com/docs', 'included' => true }]
    manifest << { 'url' => 'https://example.com/keep', 'included' => true } if additional_page
    version = ChatRing::KnowledgeVersion.create!(
      account: account,
      inbox: inbox,
      status: 'ingesting',
      root_url: 'https://example.com/',
      provider_release: 'provider-release',
      mapped_manifest: manifest,
      manifest_digest: Digest::SHA256.hexdigest(manifest.to_json)
    )
    markdown = "# Existing website\n\nWebsite knowledge that must remain in the combined version."
    version.documents.create!(
      source_url: 'https://example.com/docs',
      title: 'Existing website',
      markdown: markdown,
      content_hash: Digest::SHA256.hexdigest(markdown),
      provider_file_name: 'docs.md',
      provider_status: 'ready',
      metadata: { 'authority_class' => 'product_documentation' }
    )
    if additional_page
      markdown = '# Keep me'
      version.documents.create!(
        source_url: 'https://example.com/keep',
        title: 'Keep',
        markdown: markdown,
        content_hash: Digest::SHA256.hexdigest(markdown),
        provider_file_name: 'keep.md',
        provider_status: 'ready'
      )
    end
    version.update!(status: 'published', ready_at: Time.current, published_at: Time.current)
    version
  end
end
