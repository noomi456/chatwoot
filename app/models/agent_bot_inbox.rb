# == Schema Information
#
# Table name: agent_bot_inboxes
#
#  id           :bigint           not null, primary key
#  status       :integer          default("active"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :integer          not null
#  agent_bot_id :integer          not null
#  inbox_id     :integer          not null
#
# Indexes
#
#  index_agent_bot_inboxes_on_account_id    (account_id)
#  index_agent_bot_inboxes_on_agent_bot_id  (agent_bot_id)
#  index_agent_bot_inboxes_on_inbox_id      (inbox_id) UNIQUE
#

class AgentBotInbox < ApplicationRecord
  validates :inbox_id, presence: true, uniqueness: true
  validates :agent_bot_id, presence: true
  before_validation :ensure_account_id

  belongs_to :inbox
  belongs_to :agent_bot
  belongs_to :account
  enum status: { active: 0, inactive: 1 }

  validate :validate_inbox_account
  validate :validate_agent_bot_account

  private

  def ensure_account_id
    self.account_id = inbox&.account_id
  end

  def validate_inbox_account
    return if inbox.blank? || account.blank?
    return if inbox.account_id == account_id

    errors.add(:account, 'must match inbox account')
  end

  def validate_agent_bot_account
    return if agent_bot.blank? || agent_bot.system_bot? || account.blank?
    return if agent_bot.account_id == account_id

    errors.add(:agent_bot, 'must belong to the inbox account')
  end
end
