class ChatRing::Knowledge::FileParseJob < ApplicationJob
  queue_as :low

  def perform(source_id)
    source = ChatRing::KnowledgeFileSource.find_by(id: source_id)
    return if source.nil?

    ChatRing::Knowledge::FileParseService.new(source).call
  end
end
