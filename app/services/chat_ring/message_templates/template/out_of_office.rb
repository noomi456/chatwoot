module ChatRing::MessageTemplates::Template::OutOfOffice
  def perform
    ChatRing::MessageTemplates::TemplateEffectCollector.observe(:out_of_office, conversation) { super }
  end
end
