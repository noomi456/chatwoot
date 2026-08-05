module ChatRing::Knowledge
  Evidence = Data.define(
    :id,
    :knowledge_version_id,
    :provider,
    :provider_release,
    :provider_source_id,
    :source_reference,
    :source_title,
    :locator,
    :excerpt,
    :source_content_hash,
    :rank,
    :score,
    :retrieval_strategy
  )
end
