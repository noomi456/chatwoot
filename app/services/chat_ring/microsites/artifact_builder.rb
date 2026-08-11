require 'uri'

class ChatRing::Microsites::ArtifactBuilder
  MAX_FACTS = 6
  MAX_FACT_LENGTH = 480
  STRUCTURED_NUMBER = /(?:[$£€]\s?\d[\d,.]*|\d+(?:\.\d+)?\s?%)/

  def self.call(turn)
    new(turn).call
  end

  def initialize(turn)
    @turn = turn
  end

  def call # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    requested_types = ChatRing::Microsites::SectionContract.normalize_types(
      turn.decision_payload['microsite_section_types']
    )
    return if requested_types.empty? || !turn.decision_type.in?(%w[reply clarification])

    existing = turn.microsite_artifact
    return existing if existing

    selected = selected_evidence.to_a
    return if selected.empty?

    sections = requested_types.filter_map { |type| build_section(type, selected) }.first(3)
    return if sections.empty?

    ChatRing::MicrositeArtifact.create!(
      workspace: turn.workspace,
      ai_turn: turn,
      contract_version: ChatRing::MicrositeArtifact::CONTRACT_VERSION,
      content: {
        'title' => microsite_title(selected),
        'summary' => clean_text(turn.decision_payload['response_text'], 800),
        'sections' => sections
      },
      source_evidence_ids: selected.map(&:evidence_id),
      expires_at: Time.current + retention
    )
  end

  private

  attr_reader :turn

  def selected_evidence
    ids = Array(turn.decision_payload['evidence_ids']).map(&:to_s)
    turn.evidence.where(evidence_id: ids).order(:position).limit(MAX_FACTS)
  end

  def build_section(type, evidence) # rubocop:disable Metrics/CyclomaticComplexity
    case type
    when 'hero' then hero_section(evidence)
    when 'features_grid' then item_section(type, 'Key details', evidence)
    when 'comparison_table' then comparison_section(evidence)
    when 'stats_banner' then stats_section(evidence)
    when 'faq_accordion' then faq_section(evidence)
    when 'cta_banner' then cta_section(evidence)
    when 'content_carousel' then item_section(type, 'Explore the details', evidence)
    when 'testimonial_carousel' then testimonial_section(evidence)
    when 'social_proof_grid' then social_proof_section(evidence)
    when 'booking_section' then booking_section
    when 'content' then content_section(evidence)
    when 'product_gallery' then item_section(type, 'Recommended options', evidence)
    when 'interactive_calculator', 'video_hero', 'image_carousel', 'video_embed', 'image_gallery', 'location_map'
      nil
    end
  end

  def hero_section(evidence)
    fact = fact_for(evidence.first)
    {
      'type' => 'hero',
      'title' => microsite_title(evidence),
      'body' => clean_text(turn.decision_payload['response_text'], 800),
      'source' => fact.slice('title', 'url')
    }
  end

  def item_section(type, title, evidence)
    {
      'type' => type,
      'title' => title,
      'items' => evidence.map { |item| fact_for(item) }
    }
  end

  def comparison_section(evidence)
    facts = evidence.map { |item| fact_for(item) }.select { |fact| fact['body'].match?(STRUCTURED_NUMBER) }
    return if facts.length < 2

    { 'type' => 'comparison_table', 'title' => 'Compare verified details', 'items' => facts }
  end

  def stats_section(evidence)
    stats = evidence.flat_map do |item|
      body = clean_text(item.excerpt, MAX_FACT_LENGTH)
      body.scan(STRUCTURED_NUMBER).first(2).map do |value|
        { 'value' => value, 'label' => clean_text(item.source_title, 120) }
      end
    end.first(4)
    return if stats.empty?

    { 'type' => 'stats_banner', 'title' => 'Verified figures', 'items' => stats }
  end

  def faq_section(evidence)
    items = evidence.map do |item|
      fact = fact_for(item)
      heading = Array(item.heading_path).last.to_s.presence || fact['title']
      { 'question' => "What should I know about #{clean_text(heading, 120)}?", 'answer' => fact['body'], 'url' => fact['url'] }.compact
    end
    { 'type' => 'faq_accordion', 'title' => 'Questions and answers', 'items' => items }
  end

  def cta_section(evidence)
    candidate = evidence.lazy.flat_map { |item| Array(item.metadata['cta_candidates']) }.map(&:to_h).find do |item|
      ChatRing::Knowledge::MarkdownStructure.safe_public_http_url?(item.stringify_keys['url'])
    end
    return unless candidate

    candidate = candidate.stringify_keys
    {
      'type' => 'cta_banner',
      'title' => clean_text(candidate['label'], 120),
      'url' => candidate['url']
    }
  end

  def testimonial_section(evidence)
    items = evidence.filter_map do |item|
      body = clean_text(item.excerpt, MAX_FACT_LENGTH)
      next unless body.match?(/[“”\"]/) && body.length <= MAX_FACT_LENGTH

      { 'quote' => body, 'source' => clean_text(item.source_title, 120), 'url' => safe_url(item.public_url) }.compact
    end
    return if items.empty?

    { 'type' => 'testimonial_carousel', 'title' => 'What customers say', 'items' => items }
  end

  def social_proof_section(evidence)
    section = stats_section(evidence)
    return unless section

    section.merge('type' => 'social_proof_grid', 'title' => 'Verified results')
  end

  def booking_section
    authorization = ChatRing::Tools::RequestAppointmentAuthorization.call(
      turn,
      presentation_context: 'microsite_booking_section'
    )
    payload = authorization.renderer_result.payload
    url = safe_url(payload['approved_url'])
    return unless url

    {
      'type' => 'booking_section',
      'title' => clean_text(payload['link_label'].presence || 'Book a meeting', 80),
      'provider' => payload['provider'],
      'url' => url
    }
  rescue ChatRing::Tools::OutcomePreparer::Rejected
    nil
  end

  def content_section(evidence)
    {
      'type' => 'content',
      'title' => microsite_title(evidence),
      'body' => clean_text(turn.decision_payload['response_text'], 1200),
      'items' => evidence.map { |item| fact_for(item) }
    }
  end

  def fact_for(evidence)
    {
      'title' => clean_text(evidence.source_title, 160),
      'body' => clean_text(evidence.excerpt, MAX_FACT_LENGTH),
      'url' => safe_url(evidence.public_url)
    }.compact
  end

  def microsite_title(evidence)
    heading = Array(evidence.first.heading_path).last.to_s.presence
    clean_text(heading || evidence.first.source_title || 'Your personalized guide', 160)
  end

  def clean_text(value, maximum)
    ActionView::Base.full_sanitizer.sanitize(value.to_s).squish.truncate(maximum, omission: '…')
  end

  def safe_url(value)
    url = value.to_s
    url if ChatRing::Knowledge::MarkdownStructure.safe_public_http_url?(url)
  end

  def retention
    days = Integer(ENV.fetch('CHATRING_MICROSITE_RETENTION_DAYS', 7))
    days.in?([1, 7]) ? days.days : ChatRing::MicrositeArtifact::DEFAULT_RETENTION
  rescue ArgumentError, TypeError
    ChatRing::MicrositeArtifact::DEFAULT_RETENTION
  end
end
