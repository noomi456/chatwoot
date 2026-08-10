module ChatRing::AutomationRuleListener
  NativeObservation = Data.define(:result, :effects, :error)

  def message_created(event)
    message = event.data[:message]
    return super unless message
    return super unless observed_potential_candidate?(message)
    return super unless observed_candidate?(message)

    observation = observe_native(message) { super }
    raise observation.error if observation.error

    record_automation_completion(message, observation.effects) if observation.effects
    observation.result
  end

  private

  def record_automation_completion(message, effects)
    ChatRing::NativeHandling::CompletionRecorder.record_automation(message: message, effects: effects)
  rescue StandardError => e
    Rails.logger.error("[ChatRing] automation completion observation failed message_id=#{message.id} error=#{e.class.name}")
  end

  def observed_candidate?(message)
    ChatRing::NativeHandling::CompletionRecorder.candidate?(message)
  rescue StandardError => e
    log_pre_observation_failure(message, e)
    false
  end

  def observed_potential_candidate?(message)
    ChatRing::NativeHandling::CompletionRecorder.potential_candidate?(message)
  rescue StandardError => e
    log_pre_observation_failure(message, e)
    false
  end

  def observe_native(message)
    native_invoked = false
    result = nil
    native_error = nil
    effects = capture_effects(message) do
      native_invoked = true
      result = yield
    rescue StandardError => e
      native_error = e
    end

    return NativeObservation.new(result: result, effects: effects, error: native_error) if native_invoked

    NativeObservation.new(result: yield, effects: nil, error: nil)
  end

  def capture_effects(message, &)
    ChatRing::NativeHandling::AutomationEffectCollector.capture(&)
  rescue StandardError => e
    log_pre_observation_failure(message, e)
    nil
  end

  def log_pre_observation_failure(message, error)
    Rails.logger.error("[ChatRing] automation pre-observation failed message_id=#{message.id} error=#{error.class.name}")
  end
end
