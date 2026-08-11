class ChatRing::Playbooks::PhraseTriggerResolver
  Result = Data.define(:version, :reason)

  def initialize(workspace:, inbox:, text:)
    @workspace = workspace
    @inbox = inbox
    @phrase = ChatRing::Playbooks::PhraseNormalizer.call(text)
  end

  def call
    return Result.new(version: nil, reason: 'empty_or_vague_phrase') if phrase.blank?

    matches = published_versions.select { |version| version.normalized_trigger_phrases.include?(phrase) }
    return Result.new(version: matches.first, reason: 'exact_phrase') if matches.one?
    return Result.new(version: nil, reason: 'ambiguous_phrase') if matches.many?

    Result.new(version: nil, reason: 'no_phrase_match')
  end

  private

  attr_reader :workspace, :inbox, :phrase

  def published_versions
    workspace.inbox_playbooks.active
             .where(chatwoot_inbox_id: inbox.id)
             .includes(:current_version)
             .filter_map(&:current_version)
  end
end
