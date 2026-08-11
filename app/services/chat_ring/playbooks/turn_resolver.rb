class ChatRing::Playbooks::TurnResolver
  Result = Data.define(:execution, :started, :reason)

  def initialize(message:, workspace:)
    @message = message
    @workspace = workspace
  end

  def call
    execution = controlling_execution
    return continue_execution(execution) if execution

    trigger = ChatRing::Playbooks::PhraseTriggerResolver.new(
      workspace: workspace,
      inbox: message.conversation.inbox,
      text: message.content
    ).call
    return Result.new(execution: nil, started: false, reason: trigger.reason) unless trigger.version

    start_execution(trigger.version)
  rescue ActiveRecord::RecordNotUnique
    execution = controlling_execution
    Result.new(execution: execution, started: false, reason: 'concurrent_execution')
  end

  private

  attr_reader :message, :workspace

  def controlling_execution
    ChatRing::InboxPlaybookExecution.controlling.lock.find_by(
      workspace: workspace,
      conversation: message.conversation
    )
  end

  def continue_execution(execution)
    execution.update!(last_trigger_message: message)
    Result.new(execution: execution, started: false, reason: 'active_execution')
  end

  def start_execution(version)
    execution = ChatRing::InboxPlaybookExecution.create!(
      workspace: workspace,
      conversation: message.conversation,
      inbox_playbook_version: version,
      current_step_id: version.definition.fetch('entry_step_id'),
      status: :active,
      last_trigger_message: message,
      started_at: Time.current
    )
    Result.new(execution: execution, started: true, reason: 'exact_phrase')
  end
end
