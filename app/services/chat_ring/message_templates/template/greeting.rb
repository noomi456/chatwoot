module ChatRing::MessageTemplates::Template::Greeting
  def perform
    ChatRing::MessageTemplates::TemplateEffectCollector.observe(:greeting, conversation) { super }
  end
end
