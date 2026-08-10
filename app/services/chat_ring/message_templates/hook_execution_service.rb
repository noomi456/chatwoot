module ChatRing::MessageTemplates::HookExecutionService
  def perform
    return super unless observed_potential_candidate?

    observation = observed_template_observation
    return super if observation.nil?

    result = nil
    effects = ChatRing::MessageTemplates::TemplateEffectCollector.capture { result = super }
    record_template_completion(observation, effects)
    result
  end

  private

  def record_template_completion(observation, effects)
    ChatRing::NativeHandling::CompletionRecorder.record_template(
      message: message,
      observation: observation,
      effects: effects
    )
  rescue StandardError => e
    Rails.logger.error("[ChatRing] template completion observation failed message_id=#{message.id} error=#{e.class.name}")
  end

  def observed_template_observation
    ChatRing::NativeHandling::CompletionRecorder.template_observation(message)
  rescue StandardError => e
    log_pre_observation_failure(e)
    nil
  end

  def observed_potential_candidate?
    ChatRing::NativeHandling::CompletionRecorder.potential_candidate?(message)
  rescue StandardError => e
    log_pre_observation_failure(e)
    false
  end

  def log_pre_observation_failure(error)
    Rails.logger.error("[ChatRing] template pre-observation failed message_id=#{message.id} error=#{error.class.name}")
  end
end
