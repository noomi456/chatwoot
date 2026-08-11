class ChatRing::Playbooks::Publisher
  class InvalidRevision < StandardError; end

  class InvalidDefinition < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super('Inbox Playbook definition is invalid')
    end
  end

  def initialize(playbook:, actor:, expected_lock_version:)
    @playbook = playbook
    @actor = actor
    @expected_lock_version = Integer(expected_lock_version)
  end

  def call
    Account.transaction do
      Account.lock.find(playbook.workspace.chatwoot_account_id)
      Inbox.lock.find(playbook.chatwoot_inbox_id)
      locked = ChatRing::InboxPlaybook.lock.find(playbook.id)
      validate_revision!(locked)
      result = ChatRing::Playbooks::DefinitionValidator.new(playbook: locked, definition: locked.draft_definition).call
      raise InvalidDefinition, result unless result.valid?

      version = publish_version!(locked, result)
      locked.update!(current_version: version, status: :active)
      version
    end
  end

  private

  attr_reader :playbook, :actor, :expected_lock_version

  def validate_revision!(locked)
    raise InvalidRevision, 'Inbox Playbook changed; reload before publishing' unless locked.lock_version == expected_lock_version
    raise ActiveRecord::RecordNotSaved, 'Archived Inbox Playbooks are read-only' if locked.archived?
  end

  def publish_version!(locked, result)
    locked.versions.create!(
      version: locked.versions.maximum(:version).to_i + 1,
      name: locked.name,
      purpose: locked.purpose,
      definition: result.definition,
      capability_snapshot: result.capability_snapshot,
      validation_result: result.as_json,
      created_by: actor,
      published_at: Time.current
    )
  end
end
