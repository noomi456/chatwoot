module ChatRing::KnowledgeManagementSerialization
  private

  def serialize_file_source(source, include_content: false)
    file_source_identity(source)
      .merge(file_source_content_summary(source))
      .merge(file_source_timestamps(source))
      .tap { |result| result[:markdown] = source.markdown if include_content }
  end

  def file_source_identity(source)
    {
      id: source.id,
      inbox_id: source.inbox_id,
      filename: source.original_filename,
      source_reference: source.source_reference,
      source_kind: source.source_kind,
      status: source.status,
      content_type: source.content_type,
      byte_size: source.byte_size,
      authority_class: source.authority_class
    }
  end

  def file_source_content_summary(source)
    {
      raw_content_hash: source.raw_content_hash,
      content_hash: source.content_hash,
      page_count: source.metadata['page_count'],
      table_count: source.metadata['table_count'].to_i,
      character_count: source.markdown.to_s.length,
      headings: source.metadata['headings'] || [],
      cta_candidates: source.metadata['cta_candidates'] || [],
      failure_code: source.failure_code,
      failure_message: source.failure_message
    }
  end

  def file_source_timestamps(source)
    {
      parsed_at: source.parsed_at,
      disabled_at: source.disabled_at,
      created_at: source.created_at,
      updated_at: source.updated_at
    }
  end

  def serialize_version(version, include_documents: false)
    result = version_identity(version).merge(version_status(version))
    result[:documents] = version.documents.order(:id).map { |document| serialize_document(document) } if include_documents
    result
  end

  def version_identity(version)
    {
      id: version.id,
      inbox_id: version.inbox_id,
      root_url: version.root_url,
      provider: version.provider,
      provider_release: version.provider_release,
      build_mode: version.config_snapshot['build_mode'] || 'website_map_and_scrape'
    }
  end

  def version_status(version)
    {
      status: version.status,
      evaluation_status: version.evaluation_status,
      evaluation_report: version.evaluation_report,
      failure_code: version.failure_code,
      failure_message: version.failure_message,
      ready_at: version.ready_at,
      published_at: version.published_at,
      created_at: version.created_at,
      document_count: version.documents.size,
      publish_on_ready: version.config_snapshot['publish_on_ready'] == true
    }
  end

  def serialize_document(document)
    {
      id: document.id,
      source_kind: document.source_kind,
      source_reference: document.source_reference,
      public_url: document.public_url,
      title: document.title,
      content_hash: document.content_hash,
      authority_class: document.metadata['authority_class'],
      headings: document.metadata['headings'] || [],
      cta_candidates: document.metadata['cta_candidates'] || [],
      provider_status: document.provider_status,
      markdown: document.markdown,
      character_count: document.markdown.to_s.length,
      updated_at: document.updated_at
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
