class ChatRing::Brain::CredentialResolver
  Credential = Data.define(:provider, :api_key, :api_base)
  SUPPORTED_PROVIDERS = %w[openai].freeze

  def self.resolve(assistant_version)
    provider = assistant_version.llm_provider
    raise ArgumentError, 'Unsupported ChatRing LLM provider' unless SUPPORTED_PROVIDERS.include?(provider)

    api_key = ENV['CHATRING_LLM_API_KEY'].presence
    raise KeyError, 'CHATRING_LLM_API_KEY is not configured' if api_key.blank?

    Credential.new(
      provider: provider,
      api_key: api_key,
      api_base: ENV['CHATRING_LLM_API_BASE'].presence
    )
  end
end
