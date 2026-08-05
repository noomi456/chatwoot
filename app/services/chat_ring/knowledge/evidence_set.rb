module ChatRing::Knowledge
  EvidenceSet = Data.define(
    :knowledge_version_id,
    :provider,
    :provider_release,
    :query,
    :retrieval_strategy,
    :retrieval_configuration,
    :items
  )
end
