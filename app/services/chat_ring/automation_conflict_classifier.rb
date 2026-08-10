class ChatRing::AutomationConflictClassifier
  CONFLICTING_ACTIONS = %w[
    send_message
    send_attachment
    assign_team
    assign_agent
    remove_assigned_agent
    remove_assigned_team
    send_webhook_event
    change_status
    resolve_conversation
    open_conversation
    pending_conversation
    snooze_conversation
  ].freeze
  INDIRECT_ACTIONS = %w[send_webhook_event].freeze

  def self.rule_conflicts?(rule, inbox)
    new(account: rule.account, inbox: inbox).rule_conflicts?(rule)
  end

  def initialize(account:, inbox:)
    @account = account
    @inbox = inbox
  end

  def conflicts
    account.automation_rules.active.select { |rule| rule_conflicts?(rule) }
  end

  def conflicting?
    conflicts.any?
  end

  def rule_conflicts?(rule)
    conflicting_action?(rule) && potentially_matches_inbox?(rule)
  end

  private

  attr_reader :account, :inbox

  def conflicting_action?(rule)
    action_names = Array(rule.actions).map { |action| action.with_indifferent_access[:action_name].to_s }
    return action_names.intersect?(CONFLICTING_ACTIONS) unless rule.event_name == 'message_created'
    return true if action_names.intersect?(INDIRECT_ACTIONS)
    return false unless action_names.intersect?(CONFLICTING_ACTIONS)

    !incoming_message_only?(rule.conditions)
  end

  def incoming_message_only?(conditions)
    normalized = Array(conditions).map(&:with_indifferent_access)
    return false if normalized.any? { |condition| condition[:query_operator].to_s.casecmp('OR').zero? }

    normalized.any? { |condition| incoming_message_condition?(condition) }
  end

  def incoming_message_condition?(condition)
    condition[:attribute_key] == 'message_type' &&
      condition[:filter_operator] == 'equal_to' &&
      Array(condition[:values]).flatten.map(&:to_s) == ['incoming']
  end

  def potentially_matches_inbox?(rule)
    !proven_excluded_from_inbox?(rule.conditions)
  end

  def proven_excluded_from_inbox?(conditions)
    normalized = Array(conditions).map(&:with_indifferent_access)
    return false if normalized.any? { |condition| condition[:query_operator].to_s.casecmp('OR').zero? }

    normalized.select { |condition| condition[:attribute_key] == 'inbox_id' }
              .any? { |condition| inbox_condition_excludes?(condition) }
  end

  def inbox_condition_excludes?(condition)
    values = Array(condition[:values]).flatten.map(&:to_s)
    case condition[:filter_operator]
    when 'equal_to'
      values.exclude?(inbox.id.to_s)
    when 'not_equal_to'
      values.include?(inbox.id.to_s)
    else
      false
    end
  end
end
