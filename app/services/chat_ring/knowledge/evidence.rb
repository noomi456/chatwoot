module ChatRing::Knowledge
  Evidence = Data.define(
    :id,
    :knowledge_index_id,
    :provider,
    :provider_release,
    :provider_source_id,
    :provider_chunk_id,
    :source_kind,
    :source_reference,
    :source_title,
    :public_url,
    :heading_path,
    :page_locator,
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
