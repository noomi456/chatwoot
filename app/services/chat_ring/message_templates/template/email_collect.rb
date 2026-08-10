module ChatRing::MessageTemplates::Template::EmailCollect
  def perform
    ChatRing::MessageTemplates::TemplateEffectCollector.observe(:email_collection, conversation) { super }
  end
end
