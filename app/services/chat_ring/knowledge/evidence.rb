module ChatRing::Knowledge
  Evidence = Data.define(
    :id,
    :knowledge_version_id,
    :provider,
    :provider_release,
    :provider_source_id,
    :provider_chunk_id,
    :source_reference,
    :source_title,
    :heading_path,
    :page_headings,
    :cta_candidates,
    :locator,
    :authority_class,
    :excerpt,
    :source_content_hash,
    :rank,
    :score,
    :score_kind,
    :retrieval_strategy
  )
end
