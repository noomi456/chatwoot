require 'rails_helper'

RSpec.describe ChatRing::Knowledge::DocsGptClient do
  subject(:client) { described_class.new(base_url: 'http://docsgpt.internal:7091') }

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
      manifest_digest: 'manifest-sha256',
      documents: document_scope
    )
    stub_request(:post, 'http://docsgpt.internal:7091/api/upload').to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { task_id: 'task-1', source_id: 'source-1' }.to_json
    )

    expect(client.upload_version(version)).to eq(task_id: 'task-1', source_id: 'source-1')
    request_matcher = have_requested(:post, 'http://docsgpt.internal:7091/api/upload').with do |request|
      expect(request.headers['Idempotency-Key']).to eq('chatring-knowledge-version-17-manifest-sha256')
      expect(request.body.scan('name="file"').length).to eq(2)
      expect(request.body).to include('filename="home.md"', 'filename="pricing.md"', '# Home', '# Pricing')
    end
    expect(WebMock).to request_matcher
  end
end
