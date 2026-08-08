Rails.application.config.to_prepare do
  Account.include(ChatRing::Knowledge::ScopeCleanup::AccountExtension) unless Account < ChatRing::Knowledge::ScopeCleanup::AccountExtension
end
