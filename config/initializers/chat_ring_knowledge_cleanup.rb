Rails.application.config.to_prepare do
  Account.include(ChatRing::Knowledge::ScopeCleanup::AccountExtension) unless Account < ChatRing::Knowledge::ScopeCleanup::AccountExtension
  Inbox.include(ChatRing::Knowledge::ScopeCleanup::InboxExtension) unless Inbox < ChatRing::Knowledge::ScopeCleanup::InboxExtension
end
