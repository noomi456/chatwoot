class ChatRing::Microsites::SectionContract
  class Invalid < StandardError; end

  TYPES = %w[
    hero features_grid comparison_table stats_banner faq_accordion cta_banner
    interactive_calculator content_carousel testimonial_carousel social_proof_grid
    booking_section video_hero image_carousel content product_gallery video_embed
    image_gallery location_map
  ].freeze
  ALIASES = {
    'content_section' => 'content',
    'roi_calculator' => 'interactive_calculator',
    'savings_calculator' => 'interactive_calculator',
    'pricing' => 'comparison_table',
    'features' => 'features_grid',
    'faq' => 'faq_accordion'
  }.freeze

  def self.normalize_types(values)
    normalized = Array(values).filter_map do |value|
      type = value.to_s.strip
      next if type.blank?

      ALIASES.fetch(type, type)
    end.uniq
    unknown = normalized - TYPES
    raise Invalid, "Unknown microsite section types: #{unknown.join(', ')}" if unknown.present?

    normalized.freeze
  end
end
