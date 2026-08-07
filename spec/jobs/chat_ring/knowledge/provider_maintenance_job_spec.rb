require 'rails_helper'

RSpec.describe ChatRing::Knowledge::ProviderMaintenanceJob do
  it 'does not contact DocsGPT before lifecycle recovery is enabled' do
    client = instance_double(ChatRing::Knowledge::DocsGptClient, cleanup_expired_idempotency: {})
    allow(ChatRing::Knowledge::DocsGptClient).to receive(:new).and_return(client)

    with_modified_env(CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED: nil) { described_class.perform_now }

    expect(client).not_to have_received(:cleanup_expired_idempotency)
  end

  it 'uses DocsGPT housekeeping when lifecycle recovery is enabled' do
    client = instance_double(ChatRing::Knowledge::DocsGptClient, cleanup_expired_idempotency: {})
    job = described_class.new
    allow(job).to receive(:docs_gpt_client).and_return(client)

    with_modified_env(CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED: 'true') { job.perform }

    expect(client).to have_received(:cleanup_expired_idempotency)
  end
end
