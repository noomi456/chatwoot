require 'rails_helper'

RSpec.describe ChatRing::AssistantSpike::ResponseJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:agent_bot) do
    create(
      :agent_bot,
      account: account,
      outgoing_url: nil,
      bot_config: { ChatRing::AssistantSpike::BOT_CONFIG_KEY => true }
    )
  end
  let!(:agent_bot_inbox) { create(:agent_bot_inbox, account: account, inbox: inbox, agent_bot: agent_bot) }

  around do |example|
    with_modified_env CHATRING_ASSISTANT_SPIKE_ENABLED: 'true', CHATRING_ASSISTANT_SPIKE_DELAY_SECONDS: '0' do
      example.run
    end
  end

  before do
    clear_enqueued_jobs
  end

  it 'schedules one response job for an eligible committed customer message' do
    expect do
      create(:message, account: account, inbox: inbox, conversation: conversation, content: 'TEST-123')
    end.to have_enqueued_job(described_class).exactly(:once)
  end

  it 'creates one ordinary outgoing Chatwoot message when the job is retried' do
    triggering_message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'TEST-123')
    clear_enqueued_jobs

    2.times { described_class.perform_now(triggering_message.id) }

    response = conversation.messages.find_by(source_id: ChatRing::AssistantSpike.response_source_id(triggering_message))
    expect(response).to have_attributes(
      content: 'RECEIVED TEST-123',
      message_type: 'outgoing',
      sender: agent_bot
    )
    expect(conversation.messages.where(source_id: response.source_id).count).to eq(1)
    expect(SendReplyJob).to have_been_enqueued.with(response.id)
  end

  it 'discards the older job and answers only the newest rapid customer message' do
    first_message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'M1')
    second_message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'M2')
    clear_enqueued_jobs

    described_class.perform_now(first_message.id)
    described_class.perform_now(second_message.id)

    responses = conversation.messages.where(sender: agent_bot, message_type: :outgoing)
    expect(responses.pluck(:content)).to eq(['RECEIVED M2'])
  end

  it 'opens the pending conversation on human reply and suppresses the late bot response' do
    triggering_message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'WAIT')
    human = create(:user, account: account)
    clear_enqueued_jobs

    create(:message, account: account, inbox: inbox, conversation: conversation, sender: human, message_type: :outgoing)
    described_class.perform_now(triggering_message.id)

    expect(conversation.reload).to be_open
    expect(conversation.messages.where(sender: agent_bot, message_type: :outgoing)).to be_empty
  end
end
