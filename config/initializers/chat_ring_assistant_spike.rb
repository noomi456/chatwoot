Rails.application.config.to_prepare do
  unless MessageTemplates::HookExecutionService <= ChatRing::AssistantSpike::HookExtension
    MessageTemplates::HookExecutionService.prepend(ChatRing::AssistantSpike::HookExtension)
  end

  Message.prepend(ChatRing::AssistantSpike::MessageExtension) unless Message <= ChatRing::AssistantSpike::MessageExtension
end
