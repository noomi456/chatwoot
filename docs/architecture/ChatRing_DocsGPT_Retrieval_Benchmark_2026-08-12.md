# ChatRing DocsGPT Retrieval Benchmark — 2026-08-12

## Authority and boundary

- DocsGPT release: `616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66`
- Retrieval engine: the release's production `Dispatcher`
- Vector store: PostgreSQL/pgvector with the reviewed correctness backport
- Corpus: replacement immutable ChatRing KnowledgeIndex 32, 13 unique documents
- Acquisition and extraction: Firecrawl-managed ChatRing Knowledge materials
- Evidence authority: ChatRing's signed index scope, immutable provenance, hashes, authority and risk metadata

The benchmark called DocsGPT's existing `/api/sources/:source_id/search` endpoint. It did not add a proxy, search implementation, vector database, reranker, query model or answer generator.

## Benchmark set

Twelve supported queries covered integrations, Playbooks, pricing, features, Microsites, Voice, omnichannel messaging, proactive engagement and setup-time wording/paraphrases. Four unsupported controls covered payroll, refunds, SAP and cryptocurrency trading.

| Retriever | Recall@1 | Recall@3 | Recall@8 | MRR | Median latency |
| --- | ---: | ---: | ---: | ---: | ---: |
| Native classic exact | 50.0% | 91.7% | 100% | 0.697 | 153 ms |
| Native hybrid (dense + FTS + RRF) | 41.7% | 83.3% | 100% | 0.649 | 182 ms |

Native hybrid does not win on this corpus and is not promoted.

## Release decision

The production failure was not missing retrieval capability. The relevant integrations and Playbook chunks ranked within the native classic top results, but their cosine scores (`0.3045` and `0.2822`) were below the configured `0.40` cutoff.

The cutoff is also not an evidence-sufficiency boundary. Unsupported SAP, payroll and cryptocurrency questions retrieved unrelated chunks above `0.40`. Similarity is useful for candidate ranking; it cannot establish that a passage supports a business claim.

For this release:

1. Keep native DocsGPT classic exact top-k candidate retrieval.
2. Do not activate hybrid or implement BM25/RRF in ChatRing.
3. Do not discard finite, scope-valid candidates solely because their cosine score is below `0.40`.
4. Preserve finite-score, signed Account/KnowledgeIndex scope, stable chunk identity, content-hash and provenance validation.
5. Keep conversation history as untrusted discourse context; it never becomes Knowledge.
6. Permit a factual reply only through the existing structured GPT-5.4 decision contract with supplied Knowledge citations; verify supported and unsupported behavior in the real Widget before release.

If live unsupported-query behavior is not reliably abstaining, add a separately reviewed evidence-support gate. Do not reintroduce a cosine threshold as a substitute.
