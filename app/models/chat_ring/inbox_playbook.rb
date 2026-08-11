class ChatRing::InboxPlaybook < ApplicationRecord
  self.table_name = 'chat_ring_inbox_playbooks'

  enum status: { draft: 0, active: 1, disabled: 2, archived: 3 }

  belongs_to :workspace, class_name: 'ChatRing::Workspace', inverse_of: :inbox_playbooks
  belongs_to :inbox, class_name: 'Inbox', foreign_key: :chatwoot_inbox_id, inverse_of: false
  belongs_to :created_by, class_name: 'User', inverse_of: false, optional: true
  belongs_to :current_version,
             class_name: 'ChatRing::InboxPlaybookVersion',
             inverse_of: false,
             optional: true
  has_many :versions,
           class_name: 'ChatRing::InboxPlaybookVersion',
           inverse_of: :inbox_playbook,
           dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { scope: :chatwoot_inbox_id, case_sensitive: false }
  validates :purpose, length: { maximum: 500 }
  validate :draft_definition_is_an_object
  validate :inbox_belongs_to_workspace_account
  validate :current_version_belongs_to_playbook
  validate :active_playbook_has_current_version

  private

  def draft_definition_is_an_object
    errors.add(:draft_definition, 'must be an object') unless draft_definition.is_a?(Hash)
  end

  def inbox_belongs_to_workspace_account
    return if inbox.blank? || workspace.blank? || inbox.account_id == workspace.chatwoot_account_id

    errors.add(:inbox, 'must belong to the Workspace account')
  end

  def current_version_belongs_to_playbook
    return if current_version.blank? || current_version.inbox_playbook_id == id

    errors.add(:current_version, 'must belong to this Inbox Playbook')
  end

  def active_playbook_has_current_version
    return unless active? && current_version.blank?

    errors.add(:current_version, 'is required for an active Inbox Playbook')
  end
end
