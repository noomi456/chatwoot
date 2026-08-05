Rails.application.config.to_prepare do
  unless MessageTemplates::HookExecutionService.ancestors.include?(ChatRing::AssistantSpike::HookExtension)
    MessageTemplates::HookExecutionService.prepend(ChatRing::AssistantSpike::HookExtension)
  end

  Message.prepend(ChatRing::AssistantSpike::MessageExtension) unless Message.ancestors.include?(ChatRing::AssistantSpike::MessageExtension)
end
