module ChatRing::AssistantSpike
  # Public replies are enabled on this staging-validation branch so the
  # complete native Web Widget sales path can be exercised with the real model.
  # This branch must not be promoted to production before the remaining Sales
  # Core release gates pass.
  PUBLIC_AI_RELEASE_READY = true
  EXTERNAL_RUNTIME_ENABLED = false
end
