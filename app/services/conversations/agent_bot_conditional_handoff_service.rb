class Conversations::AgentBotConditionalHandoffService
  def initialize(turn)
    @turn = turn
  end

  def perform
    ActiveRecord::Base.transaction do
      Inbox.lock.find(turn.conversation.inbox_id)
      conversation = Conversation.lock.find(turn.chatwoot_conversation_id)
      ChatRing::Assistant.lock.find(turn.assistant_id)
      eligibility = ChatRing::Brain::Eligibility.check(turn.reload)
      raise Conversations::AgentBotConditionalCommitService::PreconditionFailed, eligibility.reason unless eligibility.eligible

      conversation.bot_handoff!
    end
  end

  private

  attr_reader :turn
end
