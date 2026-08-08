class ChatRing::Knowledge::FileParseJob < ApplicationJob
  queue_as :low

  def perform(source_id, parse_token = nil)
    source = ChatRing::KnowledgeFileSource.find_by(id: source_id)
    return if source.nil?

    ChatRing::Knowledge::FileParseService.new(source, parse_token: parse_token).call
  end
end
