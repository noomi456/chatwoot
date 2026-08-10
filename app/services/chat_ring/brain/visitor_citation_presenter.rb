class ChatRing::Brain::VisitorCitationPresenter
  MAX_CITATIONS = 8

  def self.call(turn)
    new(turn).call
  end

  def initialize(turn)
    @turn = turn
  end

  def call
    selected_evidence
      .filter_map { |evidence| visitor_citation(evidence) }
      .uniq { |citation| [citation['url'], citation['title']] }
      .first(MAX_CITATIONS)
  end

  private

  attr_reader :turn

  def selected_evidence
    evidence_ids = Array(turn.decision_payload['evidence_ids']).map(&:to_s)
    return ChatRing::AiTurnEvidence.none if evidence_ids.empty?

    turn.evidence.where(evidence_id: evidence_ids).order(:position)
  end

  def visitor_citation(evidence)
    url = evidence.public_url.to_s
    return unless ChatRing::Knowledge::MarkdownStructure.safe_public_http_url?(url)

    {
      'title' => evidence.source_title.to_s.truncate(160, omission: ''),
      'url' => url,
      'heading_path' => Array(evidence.heading_path).filter_map { |heading| heading.to_s.strip.presence }.first(6)
    }.compact
  end
end
