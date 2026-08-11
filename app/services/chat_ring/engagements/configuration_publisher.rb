class ChatRing::Engagements::ConfigurationPublisher
  class InvalidRevision < StandardError; end

  def initialize(workspace:, inbox:, actor:, attributes:)
    @workspace = workspace
    @inbox = inbox
    @actor = actor
    @expected_lock_version = attributes.fetch(:lock_version).to_i
    @enabled = attributes.fetch(:enabled)
    @starters = attributes.fetch(:starters)
  end

  def call
    Account.transaction do
      Account.lock.find(workspace.chatwoot_account_id)
      locked_inbox = Inbox.lock.find(inbox.id)
      engagement = ChatRing::InboxEngagement.lock.find_or_initialize_by(
        workspace: workspace,
        chatwoot_inbox_id: locked_inbox.id
      )
      raise InvalidRevision, 'Engagement configuration changed; reload and try again' unless engagement.lock_version == expected_lock_version

      engagement.update!(enabled: enabled, starters: normalized_starters, updated_by: actor)
      engagement
    end
  end

  private

  attr_reader :workspace, :inbox, :actor, :expected_lock_version, :enabled, :starters

  def normalized_starters
    starters.map do |starter|
      {
        'label' => starter.fetch('label').to_s.strip,
        'prompt' => starter.fetch('prompt').to_s.strip
      }
    end
  end
end
