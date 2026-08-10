require 'rails_helper'

RSpec.describe ChatRing::AssistantManagement::ManagedSecretRotator do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:assistant) { workspace.assistants.create!(name: 'Website Sales') }
  let(:version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { llm_provider: 'openai', llm_model: 'gpt-5.4' }
    ).call
  end

  it 'does not rotate a secret when archive wins the Account lock' do
    version
    connection = ChatRing::AssistantProvisioning::AgentBotProvisioner.new(assistant: assistant).call
    original_secret = connection.agent_bot.secret
    archive_started = Queue.new
    allow_archive_to_commit = Queue.new

    archiver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        account.reload.with_lock do
          assistant.reload.update!(status: :archived)
          archive_started << true
          allow_archive_to_commit.pop
        end
      end
    end
    archive_started.pop
    rotator = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(assistant: assistant.reload).call
      end
    rescue StandardError => e
      e
    end
    allow_archive_to_commit << true

    archiver.join
    expect(rotator.value).to be_a(ActiveRecord::RecordInvalid)
    expect(connection.agent_bot.reload.secret).to eq(original_secret)
  end
end
