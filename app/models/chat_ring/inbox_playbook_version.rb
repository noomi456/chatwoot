class ChatRing::InboxPlaybookVersion < ApplicationRecord
  self.table_name = 'chat_ring_inbox_playbook_versions'

  belongs_to :inbox_playbook,
             class_name: 'ChatRing::InboxPlaybook',
             inverse_of: :versions
  belongs_to :created_by, class_name: 'User', inverse_of: false, optional: true

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :inbox_playbook_id }
  validates :name, :published_at, presence: true
  validate :snapshot_shapes
  validate :published_snapshot_is_immutable, on: :update

  def normalized_trigger_phrases
    Array(definition['trigger_phrases'])
  end

  def tool_allowlist
    Array(definition['tool_allowlist'])
  end

  private

  def snapshot_shapes
    errors.add(:definition, 'must be an object') unless definition.is_a?(Hash)
    errors.add(:capability_snapshot, 'must be an object') unless capability_snapshot.is_a?(Hash)
    errors.add(:validation_result, 'must be an object') unless validation_result.is_a?(Hash)
  end

  def published_snapshot_is_immutable
    return if changed_attribute_names_to_save.empty?

    errors.add(:base, 'published Inbox Playbook version is immutable')
  end
end
