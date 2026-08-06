require 'rails_helper'

RSpec.describe ChatRing::Knowledge::DocsGptClient do
  subject(:client) do
    described_class.new(
      base_url: 'http://docsgpt.internal:7091',
      jwt_secret: 'jwt-secret',
      internal_key: 'internal-key',
      service_secret: 'service-secret'
    )
  end

  it 'uploads a complete website snapshot as one idempotent multi-file source' do
    documents = [
      instance_double(ChatRing::KnowledgeDocument, provider_file_name: 'home.md', markdown: '# Home'),
      instance_double(ChatRing::KnowledgeDocument, provider_file_name: 'pricing.md', markdown: '# Pricing')
    ]
    relation = instance_double(ActiveRecord::Relation, to_a: documents)
    document_scope = instance_double(ActiveRecord::Associations::CollectionProxy)
    allow(document_scope).to receive(:order).with(:id).and_return(relation)
    version = instance_double(
      ChatRing::KnowledgeVersion,
      id: 17,
      account_id: 42,
      evaluation_binding_digest: 'a' * 64,
      documents: document_scope
    )
    stub_request(:post, 'http://docsgpt.internal:7091/api/upload').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { task_id: 'task-1', source_id: 'source-1' }.to_json
    )

    expect(client.upload_version(version)).to eq(task_id: 'task-1', source_id: 'source-1')
    request_matcher = have_requested(:post, 'http://docsgpt.internal:7091/api/upload').with do |request|
      expect(request.headers['Idempotency-Key']).to eq("chatring-knowledge-version-17-#{'a' * 64}")
      expect(request.headers['Authorization']).to match(/\ABearer /)
      expect(request.body.scan('name="file"').length).to eq(2)
      expect(request.body).to include("chatring-a42-v17-#{'a' * 64}")
      expect(request.body).to include('filename="home.md"', 'filename="pricing.md"', '# Home', '# Pricing')
    end
    expect(WebMock).to request_matcher
  end

  it 'deletes a provider source only through the scoped private endpoint' do
    endpoint = 'http://docsgpt.internal:7091/api/internal/chatring/delete-source'
    stub_request(:post, endpoint).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'deleted', source_id: 'source-1' }.to_json
    )

    response = client.delete_source(
      account_id: 42,
      knowledge_version_id: 17,
      binding_digest: 'a' * 64,
      source_id: 'source-1'
    )

    expect(response).to eq('status' => 'deleted', 'source_id' => 'source-1')
    request_matcher = have_requested(:post, endpoint).with do |request|
      headers = request.headers.transform_keys(&:downcase)
      JSON.parse(request.body) == { 'source_id' => 'source-1' } &&
        headers['x-chatring-account'] == '42' &&
        headers['x-chatring-knowledge-version'] == '17' &&
        headers['x-chatring-binding-digest'] == 'a' * 64 &&
        headers['x-chatring-signature'].match?(/\A[0-9a-f]{64}\z/)
    end
    expect(WebMock).to request_matcher
  end
end
