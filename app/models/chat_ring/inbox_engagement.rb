class ChatRing::InboxEngagement < ApplicationRecord
  self.table_name = 'chat_ring_inbox_engagements'

  MAX_STARTERS = 6
  MAX_LABEL_LENGTH = 80
  MAX_PROMPT_LENGTH = 500
  STARTER_KEYS = %w[label prompt].freeze

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :inbox_engagements
  belongs_to :inbox, class_name: 'Inbox', foreign_key: :chatwoot_inbox_id, inverse_of: false
  belongs_to :updated_by, class_name: 'User', inverse_of: false, optional: true

  validates :chatwoot_inbox_id, uniqueness: true
  validate :inbox_belongs_to_workspace_account
  validate :web_widget_inbox
  validate :starter_contracts

  def active_starters
    enabled? ? starters.deep_dup : []
  end

  private

  def inbox_belongs_to_workspace_account
    return if inbox.blank? || workspace.blank? || inbox.account_id == workspace.chatwoot_account_id

    errors.add(:inbox, 'must belong to the Workspace account')
  end

  def web_widget_inbox
    return if inbox.blank? || inbox.channel_type == 'Channel::WebWidget'

    errors.add(:inbox, 'must be a Website Inbox')
  end

  def starter_contracts
    unless starters.is_a?(Array)
      errors.add(:starters, 'must be an array')
      return
    end
    errors.add(:starters, "cannot contain more than #{MAX_STARTERS} items") if starters.length > MAX_STARTERS

    starters.each_with_index { |starter, index| validate_starter(starter, index) }
  end

  def validate_starter(starter, index)
    unless starter.is_a?(Hash) && starter.keys.sort == STARTER_KEYS
      errors.add(:starters, "item #{index + 1} must contain only label and prompt")
      return
    end

    validate_starter_text(starter['label'], index, 'label', MAX_LABEL_LENGTH)
    validate_starter_text(starter['prompt'], index, 'prompt', MAX_PROMPT_LENGTH)
  end

  def validate_starter_text(value, index, field, maximum)
    errors.add(:starters, "item #{index + 1} #{field} is required") if value.blank?
    errors.add(:starters, "item #{index + 1} #{field} is too long") if value.to_s.length > maximum
  end
end
