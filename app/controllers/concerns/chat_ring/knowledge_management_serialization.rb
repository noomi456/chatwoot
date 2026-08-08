module ChatRing::KnowledgeManagementSerialization
  private

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def serialize_material(material, include_content: false, available_to_ai: nil, active_document: nil)
    active_document ||= material.knowledge_base.active_document_for(material)
    available_to_ai = active_document.present? if available_to_ai.nil?
    visible_markdown = available_to_ai ? active_document.markdown : material.markdown
    visible_metadata = available_to_ai ? active_document.metadata : material.metadata
    visible_name = available_to_ai ? active_document.title : material.title
    visible_public_url = available_to_ai ? active_document.public_url : material.public_url
    result = {
      id: material.id,
      material_key: material.material_key,
      name: visible_name.presence || material.source_reference,
      type: material.source_kind,
      source_reference: material.source_kind == 'website' ? material.source_reference : nil,
      public_url: visible_public_url,
      characters: visible_markdown.to_s.length,
      status: material_status(material, available_to_ai),
      available_to_ai: material.active? && available_to_ai,
      authority_class: visible_metadata['authority_class'].presence || material.authority_class,
      headings: visible_metadata['headings'] || [],
      cta_candidates: visible_metadata['cta_candidates'] || [],
      risk_flags: Array(visible_metadata['risk_flags'] || material.risk_flags),
      extracted_at: material.extracted_at,
      updated_at: material.updated_at
    }
    result[:markdown] = visible_markdown if include_content
    result
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def material_status(material, available_to_ai) # rubocop:disable Metrics/CyclomaticComplexity
    return 'deleted' unless material.active?
    return 'updating' if material.status == 'updating' && available_to_ai
    return 'refresh_failed' if material.status == 'refresh_failed' && available_to_ai
    return 'available' if available_to_ai
    return 'failed' if %w[failed refresh_failed].include?(material.status)

    'processing'
  end

  def serialize_file_source(source)
    {
      id: source.id,
      filename: source.original_filename,
      type: source.source_kind,
      status: source.status,
      content_type: source.content_type,
      byte_size: source.byte_size,
      authority_class: source.authority_class,
      failure_code: source.failure_code,
      failure_message: source.failure_message,
      parsed_at: source.parsed_at,
      created_at: source.created_at,
      updated_at: source.updated_at
    }
  end
end
