require 'digest'
require 'ruby_llm'

class ChatRing::Brain::RubyLlmProvider
  MAX_REQUEST_TIMEOUT = 30
  OUTCOME_RESERVE = 2
  ERROR_CLASSIFICATIONS = [
    [[RubyLLM::RateLimitError], 'provider_rate_limited'],
    [[RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError], 'provider_unavailable'],
    [[Faraday::TimeoutError, Timeout::Error, Errno::ETIMEDOUT], 'provider_timeout'],
    [[Faraday::ConnectionFailed], 'provider_connection_failed'],
    [[RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError], 'provider_authorization_error'],
    [[RubyLLM::PaymentRequiredError], 'provider_payment_required'],
    [[RubyLLM::ConfigurationError, RubyLLM::ModelNotFoundError, RubyLLM::PromptNotFoundError,
      RubyLLM::InvalidRoleError, RubyLLM::InvalidToolChoiceError, RubyLLM::UnsupportedAttachmentError,
      KeyError, ArgumentError], 'provider_configuration_error'],
    [[RubyLLM::ContextLengthExceededError], 'provider_context_length_exceeded'],
    [[RubyLLM::BadRequestError], 'provider_bad_request'],
    [[JSON::ParserError, TypeError], 'provider_invalid_response']
  ].freeze

  class Error < StandardError
    attr_reader :code

    def initialize(code, message = code)
      @code = code
      super(message)
    end
  end

  Result = Data.define(:payload, :input_tokens, :output_tokens, :response_digest)

  def initialize(assistant_version, deadline_at: nil)
    @assistant_version = assistant_version
    @deadline_at = deadline_at
  end

  def call(messages:)
    credential = ChatRing::Brain::CredentialResolver.resolve(assistant_version)
    response = build_chat(credential, messages).ask(messages.last.fetch(:content))
    payload = normalize_payload(response.content)
    build_result(response, payload)
  rescue Error
    raise
  rescue StandardError => e
    raise Error.new(provider_error_code(e), e.message)
  end

  private

  attr_reader :assistant_version, :deadline_at

  def provider_error_code(error)
    classification = ERROR_CLASSIFICATIONS.find do |classes, _code|
      classes.any? { |error_class| error.is_a?(error_class) }
    end
    return classification.last if classification
    return generic_ruby_llm_error_code(error) if error.is_a?(RubyLLM::Error)

    'provider_unexpected_error'
  end

  def generic_ruby_llm_error_code(error)
    return 'provider_timeout' if error.response&.status.to_i == 408
    return 'provider_unavailable' if error.response&.status.to_i >= 500

    'provider_request_failed'
  end

  def ruby_llm_context(credential)
    RubyLLM.context do |config|
      config.openai_api_key = credential.api_key
      config.openai_api_base = credential.api_base if credential.api_base.present?
      config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
      config.logger = Rails.logger
      config.request_timeout = request_timeout
      config.max_retries = 0
    end
  end

  def request_timeout
    return MAX_REQUEST_TIMEOUT if deadline_at.blank?

    remaining = (deadline_at - Time.current - OUTCOME_RESERVE).floor
    raise Error, 'provider_timeout' unless remaining.positive?

    [remaining, MAX_REQUEST_TIMEOUT].min
  end

  def build_chat(credential, messages)
    chat = ruby_llm_context(credential).chat(model: assistant_version.llm_model)
    chat.with_instructions(messages.first.fetch(:content))
    chat.with_schema(ChatRing::Brain::DecisionSchema)
    chat
  end

  def build_result(response, payload)
    Result.new(
      payload: payload,
      input_tokens: response.input_tokens,
      output_tokens: response.output_tokens,
      response_digest: Digest::SHA256.hexdigest(payload.to_json)
    )
  end

  def normalize_payload(content)
    payload = content.is_a?(String) ? JSON.parse(content) : content
    raise TypeError, 'Brain provider response must be an object' unless payload.respond_to?(:to_h)

    payload.to_h.stringify_keys
  end
end
