class ChatRing::Playbooks::DraftUpdater
  class InvalidRevision < StandardError; end

  def initialize(playbook:, expected_lock_version:, attributes:)
    @playbook = playbook
    @expected_lock_version = Integer(expected_lock_version)
    @attributes = attributes.symbolize_keys.slice(:name, :purpose, :draft_definition)
  end

  def call
    Account.transaction do
      Account.lock.find(playbook.workspace.chatwoot_account_id)
      Inbox.lock.find(playbook.chatwoot_inbox_id)
      locked = ChatRing::InboxPlaybook.lock.find(playbook.id)
      raise InvalidRevision, 'Inbox Playbook changed; reload before saving' unless locked.lock_version == expected_lock_version
      raise ActiveRecord::RecordNotSaved, 'Archived Inbox Playbooks are read-only' if locked.archived?

      locked.update!(attributes)
      locked
    end
  end

  private

  attr_reader :playbook, :expected_lock_version, :attributes
end
