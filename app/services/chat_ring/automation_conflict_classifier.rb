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
    Array(rule.actions).any? do |action|
      CONFLICTING_ACTIONS.include?(action.with_indifferent_access[:action_name].to_s)
    end
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
