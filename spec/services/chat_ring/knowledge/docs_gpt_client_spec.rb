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

  let(:documents) do
    [
      instance_double(ChatRing::KnowledgeDocument, provider_file_name: 'home.md', markdown: '# Home'),
      instance_double(ChatRing::KnowledgeDocument, provider_file_name: 'pricing.md', markdown: '# Pricing')
    ]
  end
  let(:document_scope) do
    scope = instance_double(ActiveRecord::Associations::CollectionProxy)
    relation = instance_double(ActiveRecord::Relation, to_a: documents)
    allow(scope).to receive(:order).with(:id).and_return(relation)
    scope
  end
  let(:index) do
    instance_double(
      ChatRing::KnowledgeIndex,
      id: 17,
      account_id: 42,
      provider_binding_digest: 'a' * 64,
      documents: document_scope
    )
  end

  it 'uploads a complete website snapshot as one idempotent multi-file source', :aggregate_failures do
    source_id = client.expected_source_id(index)
    endpoint = 'http://docsgpt.internal:7091/api/internal/chatring/upload'
    stub_request(:post, endpoint).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { task_id: 'task-1', source_id: source_id }.to_json
    )

    expect(client.upload_index(index)).to eq(task_id: 'task-1', source_id: source_id)
    request_matcher = have_requested(:post, endpoint).with do |request|
      headers = request.headers.transform_keys(&:downcase)
      expect(request.headers['Idempotency-Key']).to eq("chatring-knowledge-index-17-#{'a' * 64}")
      expect(headers['x-internal-key']).to eq('internal-key')
      expect(headers['x-chatring-account']).to eq('42')
      expect(headers['x-chatring-knowledge-index']).to eq('17')
      expect(headers['x-chatring-binding-digest']).to eq('a' * 64)
      expect(headers['x-chatring-provider-source']).to eq("chatring-a42-i17-#{'a' * 64}")
      expect(headers['x-chatring-signature']).to match(/\A[0-9a-f]{64}\z/)
      expect(headers['authorization']).to be_nil
      expect(request.body.scan('name="file"').length).to eq(2)
      expect(request.body).to include("chatring-a42-i17-#{'a' * 64}")
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
      knowledge_index_id: 17,
      binding_digest: 'a' * 64,
      source_id: 'source-1'
    )

    expect(response).to eq('status' => 'deleted', 'source_id' => 'source-1')
    request_matcher = have_requested(:post, endpoint).with do |request|
      headers = request.headers.transform_keys(&:downcase)
      JSON.parse(request.body) == { 'source_id' => 'source-1' } &&
        headers['x-chatring-account'] == '42' &&
        headers['x-chatring-knowledge-index'] == '17' &&
        headers['x-chatring-binding-digest'] == 'a' * 64 &&
        headers['x-chatring-signature'].match?(/\A[0-9a-f]{64}\z/)
    end
    expect(WebMock).to request_matcher
  end

  it 'reads ingestion task status through the same signed source scope' do
    endpoint = 'http://docsgpt.internal:7091/api/internal/chatring/task-status?source_id=source-1&task_id=task-1'
    stub_request(:get, endpoint).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'processing', progress: 50 }.to_json
    )

    expect(client.task_status(index, 'task-1', 'source-1')).to eq('status' => 'processing', 'progress' => 50)
    request_matcher = have_requested(:get, endpoint).with do |request|
      headers = request.headers.transform_keys(&:downcase)
      headers['x-chatring-account'] == '42' &&
        headers['x-chatring-knowledge-index'] == '17' &&
        headers['x-chatring-binding-digest'] == 'a' * 64 &&
        headers['x-chatring-signature'].match?(/\A[0-9a-f]{64}\z/)
    end
    expect(WebMock).to request_matcher
  end

  it 'rejects malformed success responses from private mutation endpoints' do
    stub_request(:post, 'http://docsgpt.internal:7091/api/internal/chatring/delete-source').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { status: 'deleted', source_id: 'other-source' }.to_json
    )

    expect do
      client.delete_source(
        account_id: 42,
        knowledge_index_id: 17,
        binding_digest: 'a' * 64,
        source_id: 'source-1'
      )
    end.to raise_error(described_class::ResponseError, /deletion response is invalid/)
  end
end
