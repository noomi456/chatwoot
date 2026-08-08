module ChatRing::KnowledgeManagementSerialization
  private

  def serialize_material(material, include_content: false, available_to_ai: nil)
    available_to_ai = material.knowledge_base.active_knowledge_index&.documents&.exists?(knowledge_material_id: material.id) \
      if available_to_ai.nil?
    result = {
      id: material.id,
      material_key: material.material_key,
      name: material.title.presence || material.source_reference,
      type: material.source_kind,
      source_reference: material.source_reference,
      public_url: material.public_url,
      characters: material.markdown.to_s.length,
      status: material_status(material, available_to_ai),
      available_to_ai: material.active? && available_to_ai,
      authority_class: material.authority_class,
      headings: material.metadata['headings'] || [],
      cta_candidates: material.metadata['cta_candidates'] || [],
      risk_flags: material.risk_flags,
      extracted_at: material.extracted_at,
      updated_at: material.updated_at
    }
    result[:markdown] = material.markdown if include_content
    result
  end

  def material_status(material, available_to_ai)
    return 'deleted' unless material.active?
    return 'updating' if material.status == 'updating' && available_to_ai
    return 'refresh_failed' if material.status == 'refresh_failed' && available_to_ai
    return 'available' if available_to_ai
    return 'failed' if %w[failed refresh_failed].include?(material.status)

    'processing'
  end

  def serialize_website_source(source)
    {
      id: source.id,
      source_type: source.source_type,
      root_url: source.root_url,
      status: source.status,
      mapped_pages: source.mapped_manifest,
      crawl_errors: source.crawl_errors,
      failure_code: source.failure_code,
      failure_message: source.failure_message,
      last_processed_at: source.last_processed_at,
      created_at: source.created_at,
      updated_at: source.updated_at
    }
  end

  def serialize_file_source(source)
    {
      id: source.id,
      filename: source.original_filename,
      source_reference: source.source_reference,
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

  def serialize_evidence_set(evidence_set)
    evidence_set.to_h.merge(items: evidence_set.items.map do |evidence|
      evidence.to_h.merge(
        page_headings: evidence.page_headings.map(&:to_h),
        cta_candidates: evidence.cta_candidates.map(&:to_h)
      )
    end)
  end
end
