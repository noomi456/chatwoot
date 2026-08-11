class ChatRing::Playbooks::ToolPolicyGuard
  class InvalidActivePlaybooks < StandardError; end

  def initialize(workspace:, inbox:, enabled_tools:)
    @workspace = workspace
    @inbox = inbox
    @enabled_identifiers = enabled_tools.to_set { |item| "#{item.fetch('key')}@#{item.fetch('version')}" }
  end

  def call
    broken = workspace.inbox_playbooks.active
                      .where(chatwoot_inbox_id: inbox.id)
                      .includes(:current_version)
                      .filter_map do |playbook|
      required = playbook.current_version.tool_allowlist.map { |item| "#{item.fetch('key')}@#{item.fetch('version')}" }
      playbook.name if (required.to_set - enabled_identifiers).present?
    end
    return if broken.empty?

    raise InvalidActivePlaybooks, "Tool policy would invalidate published Inbox Playbooks: #{broken.join(', ')}"
  end

  private

  attr_reader :workspace, :inbox, :enabled_identifiers
end
