class ChatRing::InboxToolPolicy < ApplicationRecord
  self.table_name = 'chat_ring_inbox_tool_policies'

  enum status: { active: 0, disabled: 1 }

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :inbox_tool_policies
  belongs_to :inbox, class_name: 'Inbox', foreign_key: :chatwoot_inbox_id, inverse_of: false
  belongs_to :current_version,
             class_name: 'ChatRing::InboxToolPolicyVersion',
             inverse_of: false,
             optional: true
  has_many :versions,
           class_name: 'ChatRing::InboxToolPolicyVersion',
           inverse_of: :inbox_tool_policy,
           dependent: :destroy

  validates :chatwoot_inbox_id, uniqueness: true
  validate :inbox_belongs_to_workspace_account
  validate :current_version_belongs_to_policy

  private

  def inbox_belongs_to_workspace_account
    return if inbox.blank? || workspace.blank? || inbox.account_id == workspace.chatwoot_account_id

    errors.add(:inbox, 'must belong to the Workspace account')
  end

  def current_version_belongs_to_policy
    return if current_version.blank? || current_version.inbox_tool_policy_id == id

    errors.add(:current_version, 'must belong to this Inbox Tool policy')
  end
end
