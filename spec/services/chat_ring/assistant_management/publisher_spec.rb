require 'rails_helper'

RSpec.describe ChatRing::AssistantManagement::Publisher do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:assistant) { workspace.assistants.create!(name: 'Website Sales') }

  it 'preserves hidden existing configuration and the exact published legacy model when publishing an edited draft' do
    current_version = ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: {
        llm_provider: 'openai',
        llm_model: 'gpt-4.1',
        conversation_policy: { 'history_limit' => 10 }
      }
    ).call
    draft = assistant.create_configuration_draft!(
      knowledge_scope: scope,
      instructions: current_version.instructions,
      conversation_policy: current_version.conversation_policy,
      llm_provider: current_version.llm_provider,
      llm_model: current_version.llm_model,
      published_version: current_version
    )
    draft.update!(instructions: 'Use the current Business Knowledge Base.')

    version = described_class.new(assistant: assistant, expected_lock_version: draft.lock_version).call

    expect(version).to have_attributes(
      version: 2,
      llm_model: 'gpt-4.1',
      conversation_policy: { 'history_limit' => 10 },
      instructions: 'Use the current Business Knowledge Base.'
    )
  end

  it 'checks the requested draft revision only after acquiring the Assistant lock' do
    draft = assistant.create_configuration_draft!(knowledge_scope: scope)
    update_started = Queue.new
    allow_update_to_commit = Queue.new

    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        assistant.reload.with_lock do
          assistant.configuration_draft.update!(instructions: 'New committed instructions')
          update_started << true
          allow_update_to_commit.pop
        end
      end
    end
    update_started.pop
    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(assistant: assistant.reload, expected_lock_version: draft.lock_version).call
      end
    rescue StandardError => e
      e
    end
    allow_update_to_commit << true

    updater.join
    expect(publisher.value).to be_a(ActiveRecord::StaleObjectError)
    expect(assistant.versions).to be_empty
  end

  it 'repairs the managed AgentBot boundary when the current draft is republished unchanged' do
    draft = assistant.create_configuration_draft!(knowledge_scope: scope)
    first_version = described_class.new(assistant: assistant, expected_lock_version: draft.lock_version).call
    agent_bot = assistant.agent_bot_connection.agent_bot
    agent_bot.update!(outgoing_url: 'https://example.test/self-webhook')

    same_version = described_class.new(
      assistant: assistant.reload,
      expected_lock_version: draft.reload.lock_version
    ).call

    expect(same_version).to eq(first_version)
    expect(agent_bot.reload.outgoing_url).to be_nil
    expect(assistant.versions.count).to eq(1)
  end

  it 'rejects publication when archive wins the Account lock' do
    draft = assistant.create_configuration_draft!(knowledge_scope: scope)
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
    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(assistant: assistant.reload, expected_lock_version: draft.lock_version).call
      end
    rescue StandardError => e
      e
    end
    allow_archive_to_commit << true

    archiver.join
    expect(publisher.value).to be_a(ActiveRecord::RecordInvalid)
    expect(assistant.versions).to be_empty
  end
end
