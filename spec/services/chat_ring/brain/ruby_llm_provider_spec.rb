require 'rails_helper'

RSpec.describe ChatRing::Brain::RubyLlmProvider do
  let(:account) { create(:account) }
  let(:workspace) { account.chat_ring_workspace }
  let(:assistant) { ChatRing::Assistant.create!(workspace: workspace, name: 'Support') }
  let(:scope) { workspace.knowledge_scopes.find_by!(business_wide: true) }
  let(:version) do
    ChatRing::AssistantVersions::Publisher.new(
      assistant: assistant,
      knowledge_scope: scope,
      configuration: { llm_provider: 'openai', llm_model: 'gpt-5.4' }
    ).call
  end
  let(:context) { instance_double(RubyLLM::Context) }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:configuration) { instance_double(RubyLLM::Configuration) }
  let(:deadline_at) { 20.seconds.from_now }

  before do
    allow(configuration).to receive(:openai_api_key=)
    allow(configuration).to receive(:openai_api_base=)
    allow(configuration).to receive(:model_registry_file=)
    allow(configuration).to receive(:logger=)
    allow(configuration).to receive(:request_timeout=)
    allow(configuration).to receive(:max_retries=)
    allow(RubyLLM).to receive(:context) do |&block|
      block.call(configuration)
      context
    end
    allow(context).to receive(:chat).with(model: 'gpt-5.4').and_return(chat)
    allow(chat).to receive(:with_instructions).and_return(chat)
    allow(chat).to receive(:with_schema).with(ChatRing::Brain::DecisionSchema).and_return(chat)
  end

  it 'uses ChatRing deployment credentials and returns a structured provider result' do
    response = instance_double(
      RubyLLM::Message,
      content: {
        'decision_type' => 'reply', 'response_text' => 'Grounded answer',
        'reason_code' => 'answered', 'evidence_ids' => ['evidence-1']
      },
      input_tokens: 20,
      output_tokens: 8
    )
    allow(chat).to receive(:ask).with('turn context').and_return(response)

    with_modified_env CHATRING_LLM_API_KEY: 'secret', CHATRING_LLM_API_BASE: 'https://llm.example/v1' do
      result = described_class.new(version, deadline_at: deadline_at).call(
        messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
      )

      expect(result.payload).to include('decision_type' => 'reply')
      expect(result).to have_attributes(input_tokens: 20, output_tokens: 8)
      expect(configuration).to have_received(:openai_api_key=).with('secret')
      expect(configuration).to have_received(:openai_api_base=).with('https://llm.example/v1')
      expect(configuration).to have_received(:request_timeout=).with(be_between(1, 20))
      expect(configuration).to have_received(:max_retries=).with(0)
    end
  end

  it 'returns a typed configuration failure without consulting Captain credentials' do
    with_modified_env CHATRING_LLM_API_KEY: nil do
      expect do
        described_class.new(version).call(
          messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
        )
      end.to raise_error(described_class::Error) { |error| expect(error.code).to eq('provider_configuration_error') }
    end

    expect(RubyLLM).not_to have_received(:context)
  end

  it 'maps a transport deadline to a typed provider timeout without an internal retry' do
    allow(chat).to receive(:ask).and_raise(Faraday::TimeoutError, 'execution expired')

    with_modified_env CHATRING_LLM_API_KEY: 'secret' do
      expect do
        described_class.new(version, deadline_at: deadline_at).call(
          messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
        )
      end.to raise_error(described_class::Error) { |error| expect(error.code).to eq('provider_timeout') }
    end

    expect(configuration).to have_received(:max_retries=).with(0)
  end

  it 'maps the installed RubyLLM transient errors to retryable provider codes' do
    {
      RubyLLM::RateLimitError => 'provider_rate_limited',
      RubyLLM::ServiceUnavailableError => 'provider_unavailable',
      Faraday::ConnectionFailed => 'provider_connection_failed'
    }.each do |error_class, expected_code|
      allow(chat).to receive(:ask).and_raise(error_class, 'temporary provider failure')

      with_modified_env CHATRING_LLM_API_KEY: 'secret' do
        expect do
          described_class.new(version, deadline_at: deadline_at).call(
            messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
          )
        end.to raise_error(described_class::Error) { |error| expect(error.code).to eq(expected_code) }
      end
    end
  end

  it 'maps authorization and request errors to permanent provider codes' do
    {
      RubyLLM::UnauthorizedError => 'provider_authorization_error',
      RubyLLM::BadRequestError => 'provider_bad_request',
      RubyLLM::ContextLengthExceededError => 'provider_context_length_exceeded'
    }.each do |error_class, expected_code|
      allow(chat).to receive(:ask).and_raise(error_class, 'permanent provider failure')

      with_modified_env CHATRING_LLM_API_KEY: 'secret' do
        expect do
          described_class.new(version, deadline_at: deadline_at).call(
            messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
          )
        end.to raise_error(described_class::Error) { |error| expect(error.code).to eq(expected_code) }
      end
    end
  end

  it 'does not classify an unknown application exception as a retryable provider outage' do
    allow(chat).to receive(:ask).and_raise(StandardError, 'unexpected application failure')

    with_modified_env CHATRING_LLM_API_KEY: 'secret' do
      expect do
        described_class.new(version, deadline_at: deadline_at).call(
          messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
        )
      end.to raise_error(described_class::Error) { |error| expect(error.code).to eq('provider_unexpected_error') }
    end
  end

  it 'maps a generic RubyLLM HTTP 408 response to the retryable timeout code' do
    response = instance_double(Faraday::Response, status: 408, body: 'request timeout')
    allow(chat).to receive(:ask).and_raise(RubyLLM::Error.new(response))

    with_modified_env CHATRING_LLM_API_KEY: 'secret' do
      expect do
        described_class.new(version, deadline_at: deadline_at).call(
          messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
        )
      end.to raise_error(described_class::Error) { |error| expect(error.code).to eq('provider_timeout') }
    end
  end

  it 'refuses to start a provider call when only the reserved outcome budget remains' do
    allow(chat).to receive(:ask)

    with_modified_env CHATRING_LLM_API_KEY: 'secret' do
      expect do
        described_class.new(version, deadline_at: 1.second.from_now).call(
          messages: [{ role: 'system', content: 'system policy' }, { role: 'user', content: 'turn context' }]
        )
      end.to raise_error(described_class::Error) { |error| expect(error.code).to eq('provider_timeout') }
    end

    expect(chat).not_to have_received(:ask)
  end
end
