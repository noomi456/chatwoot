require 'rails_helper'

RSpec.describe ChatRing::Knowledge::LifecycleReconciliationJob do
  it 'is inert until the deployment explicitly enables recovery' do
    allow(ChatRing::Knowledge::FileSourceReconciler).to receive(:call)
    allow(ChatRing::Knowledge::AbandonmentService).to receive(:abandon_overdue_evaluation_failures!)
    allow(ChatRing::Knowledge::ProviderCleanupReconciler).to receive(:call)

    with_modified_env(CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED: nil) { described_class.perform_now }

    expect(ChatRing::Knowledge::FileSourceReconciler).not_to have_received(:call)
    expect(ChatRing::Knowledge::AbandonmentService).not_to have_received(:abandon_overdue_evaluation_failures!)
    expect(ChatRing::Knowledge::ProviderCleanupReconciler).not_to have_received(:call)
  end

  it 'runs abandonment and cleanup recovery when explicitly enabled' do
    allow(ChatRing::Knowledge::FileSourceReconciler).to receive(:call)
    allow(ChatRing::Knowledge::AbandonmentService).to receive(:abandon_overdue_evaluation_failures!)
    allow(ChatRing::Knowledge::ProviderCleanupReconciler).to receive(:call)

    with_modified_env(CHATRING_KNOWLEDGE_LIFECYCLE_RECONCILIATION_ENABLED: 'true') { described_class.perform_now }

    expect(ChatRing::Knowledge::FileSourceReconciler).to have_received(:call)
    expect(ChatRing::Knowledge::AbandonmentService).to have_received(:abandon_overdue_evaluation_failures!)
    expect(ChatRing::Knowledge::ProviderCleanupReconciler).to have_received(:call)
  end
end
