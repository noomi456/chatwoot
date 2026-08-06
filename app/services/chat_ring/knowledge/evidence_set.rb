module ChatRing::Knowledge
  EvidenceSet = Data.define(
    :knowledge_version_id,
    :provider,
    :provider_release,
    :query,
    :status,
    :error_code,
    :latency_ms,
    :retrieval_strategy,
    :retrieval_configuration,
    :items
  )
end
