class ChatRing::NativeHandling::AutomationEffectPolicy
  LIFECYCLE_ATTRIBUTES = %w[status assignee_id assignee_agent_bot_id team_id].freeze

  def self.terminal_reason(snapshot)
    new(snapshot).terminal_reason
  end

  def initialize(snapshot)
    @snapshot = snapshot
  end

  def terminal_reason
    return 'automation_observation_failed' unless completed?
    return 'automation_observation_failed' if observation_failed?
    return 'native_automation_response' if public_response?
    return 'native_automation_lifecycle_change' if lifecycle_changed?
  end

  private

  attr_reader :snapshot

  def effects
    @effects ||= Array(snapshot&.with_indifferent_access&.fetch(:effects, nil)).map(&:with_indifferent_access)
  end

  def completed?
    snapshot.is_a?(Hash) && snapshot.with_indifferent_access[:completed] == true
  end

  def observation_failed?
    effects.any? do |effect|
      before = effect[:before].to_h.with_indifferent_access
      after = effect[:after].to_h.with_indifferent_access
      before[:observation_error].present? || after[:observation_error].present?
    end
  end

  def public_response?
    effects.any? do |effect|
      added_ids(effect, :automation_public_message_ids).any?
    end
  end

  def lifecycle_changed?
    effects.any? do |effect|
      before = effect[:before].to_h.with_indifferent_access
      after = effect[:after].to_h.with_indifferent_access
      LIFECYCLE_ATTRIBUTES.any? { |attribute| before[attribute] != after[attribute] }
    end
  end

  def added_ids(effect, key)
    before = effect[:before].to_h.with_indifferent_access
    after = effect[:after].to_h.with_indifferent_access
    Array(after[key]) - Array(before[key])
  end
end
