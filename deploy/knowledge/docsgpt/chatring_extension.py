"""ChatRing's private, score-bearing retrieval seam for pinned DocsGPT.

This module is imported by ``application.api.internal.routes`` in the derived
DocsGPT image.  It deliberately reuses DocsGPT's Dispatcher and vector store;
it does not create another answer or retrieval implementation.
"""

from __future__ import annotations

import hashlib
import hmac
import math
import os
import re
import time
import logging
from collections import defaultdict, deque
from typing import Any

from flask import jsonify, request

from application.core.model_utils import get_default_model_id
from application.core.settings import settings
from application.parser.chunking_strategies import MarkdownChunker
from application.parser.schema.base import Document
from application.retriever.dispatcher import Dispatcher
from application.storage.db.repositories.sources import SourcesRepository
from application.storage.db.session import db_readonly, db_session
from application.storage.db.source_config import RetrievalConfig
from application.storage.storage_creator import StorageCreator
from application.vectorstore.pgvector import PGVectorStore
from application.vectorstore.vector_creator import VectorCreator


MAX_QUERY_LENGTH = 2000
MAX_RESULTS = 20
MAX_CLOCK_SKEW_SECONDS = 90
DOC_TOKEN_LIMIT = 50000
_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_SOURCE_BINDING = re.compile(
    r"^chatring-a(?P<account>\d+)-v(?P<version>\d+)-(?P<digest>[0-9a-f]{64})$"
)
logger = logging.getLogger(__name__)


class ChatRingProviderError(RuntimeError):
    """A retrieval dependency failed; never reinterpret it as no evidence."""


def _service_secret() -> bytes:
    value = os.environ.get("CHATRING_SERVICE_SECRET", "")
    if not value:
        raise ChatRingProviderError("CHATRING_SERVICE_SECRET is not configured")
    return value.encode("utf-8")


def _internal_key() -> str:
    value = os.environ.get("INTERNAL_KEY", "")
    if not value:
        raise ChatRingProviderError("INTERNAL_KEY is not configured")
    return value


def _signature_payload(
    timestamp: str,
    account_id: str,
    knowledge_version_id: str,
    binding_digest: str,
    operation: str,
    source_id: str,
    body: bytes,
) -> bytes:
    body_hash = hashlib.sha256(body).hexdigest()
    return "\n".join(
        [
            timestamp,
            account_id,
            knowledge_version_id,
            binding_digest,
            operation,
            source_id,
            body_hash,
        ]
    ).encode("utf-8")


def _verify_scope(operation: str, source_id: str) -> tuple[str, str, str]:
    provided_internal_key = request.headers.get("X-Internal-Key", "")
    timestamp = request.headers.get("X-ChatRing-Timestamp", "")
    account_id = request.headers.get("X-ChatRing-Account", "")
    version_id = request.headers.get("X-ChatRing-Knowledge-Version", "")
    binding_digest = request.headers.get("X-ChatRing-Binding-Digest", "")
    provided = request.headers.get("X-ChatRing-Signature", "")
    if not provided_internal_key or not hmac.compare_digest(
        _internal_key(), provided_internal_key
    ):
        raise PermissionError("invalid internal credential")
    if not all((timestamp, account_id, version_id, binding_digest, provided)):
        raise PermissionError("missing scoped credential")
    if not binding_digest.isascii() or not re.fullmatch(r"[0-9a-f]{64}", binding_digest):
        raise PermissionError("invalid scoped credential")
    try:
        issued_at = int(timestamp)
    except ValueError as exc:
        raise PermissionError("invalid scoped credential") from exc
    if abs(int(time.time()) - issued_at) > MAX_CLOCK_SKEW_SECONDS:
        raise PermissionError("expired scoped credential")

    expected = hmac.new(
        _service_secret(),
        _signature_payload(
            timestamp,
            account_id,
            version_id,
            binding_digest,
            operation,
            source_id,
            request.get_data(cache=True),
        ),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(expected, provided):
        raise PermissionError("invalid scoped credential")
    return account_id, version_id, binding_digest


def _source(source_id: str) -> dict[str, Any] | None:
    with db_readonly() as connection:
        return SourcesRepository(connection).get(source_id, "local")


def _verify_source_binding(
    source: dict[str, Any], account_id: str, version_id: str, binding_digest: str
) -> None:
    match = _SOURCE_BINDING.fullmatch(str(source.get("name") or ""))
    if match is None or match.groupdict() != {
        "account": account_id,
        "version": version_id,
        "digest": binding_digest,
    }:
        raise PermissionError("source is outside the signed ChatRing scope")


def _delete_source(source: dict[str, Any]) -> None:
    source_id = str(source["id"])
    store = VectorCreator.create_vectorstore(settings.VECTOR_STORE, source_id)
    store.delete_index()

    file_path = source.get("file_path")
    if file_path:
        storage = StorageCreator.get_storage()
        try:
            if storage.is_directory(file_path):
                for path in storage.list_files(file_path):
                    storage.delete_file(path)
            else:
                storage.delete_file(file_path)
        except FileNotFoundError:
            pass

    with db_session() as connection:
        SourcesRepository(connection).delete(source_id, "local")


def _strict_pgvector_search(self, question, k=2, *args, score_threshold=None, **kwargs):
    """PGVector scored search that propagates failures on the ChatRing image."""
    query_vector = self._embedding.embed_query(question)
    connection = self._get_connection()
    cursor = connection.cursor()
    try:
        query = f"""
        SELECT id, {self._text_column}, {self._metadata_column},
               ({self._vector_column} <=> %s::vector) AS distance
        FROM {self._table_name}
        WHERE source_id = %s
        ORDER BY {self._vector_column} <=> %s::vector
        LIMIT %s
        """
        cursor.execute(query, (query_vector, self._source_id, query_vector, k))
        rows = cursor.fetchall()
        max_distance = None if score_threshold is None else 1.0 - float(score_threshold)
        results = []
        for row_id, text, metadata, distance in rows:
            if distance is None:
                raise ChatRingProviderError("pgvector returned a result without distance")
            resolved_distance = float(distance)
            if not math.isfinite(resolved_distance):
                raise ChatRingProviderError("pgvector returned a non-finite distance")
            if max_distance is not None and resolved_distance > max_distance:
                continue
            values = dict(metadata or {})
            values["chatring_provider_chunk_id"] = str(row_id)
            score = 1.0 - resolved_distance
            if not math.isfinite(score):
                raise ChatRingProviderError("pgvector returned a non-finite score")
            results.append((Document(text, extra_info=values).to_langchain_format(), score))
        return results
    except Exception:
        connection.rollback()
        raise
    finally:
        cursor.close()


def _document_identity(metadata: dict[str, Any]) -> str:
    source = str(metadata.get("source") or metadata.get("title") or "document")
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def _emit_markdown_chunk(
    chunker: MarkdownChunker,
    document: Document,
    index: int,
    text: str,
    heading_path: list[str],
) -> Document:
    metadata = dict(document.extra_info or {})
    document_id = _document_identity(metadata)
    content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
    metadata.update(
        {
            "chatring_document_id": document_id,
            "chatring_chunk_index": index,
            "chatring_content_hash": content_hash,
            "chatring_heading_path": " > ".join(heading_path),
            "token_count": chunker._token_count(text),
        }
    )
    return Document(
        text=text,
        doc_id=f"{document_id}:{index}:{content_hash[:16]}",
        embedding=document.embedding,
        extra_info=metadata,
    )


def _chatring_markdown_chunk(self: MarkdownChunker, documents: list[Document]):
    """Preserve heading path and stable chunk provenance during ingestion."""
    processed = []
    for document in documents:
        headings: list[tuple[int, str]] = []
        sections: list[tuple[list[str], str]] = []
        current: list[str] = []
        current_path: list[str] = []
        for line in document.text.splitlines(keepends=True):
            match = _HEADING.match(line.rstrip("\r\n"))
            if match:
                if "".join(current).strip():
                    sections.append((current_path, "".join(current)))
                level = len(match.group(1))
                headings = [entry for entry in headings if entry[0] < level]
                headings.append((level, match.group(2).strip()))
                current_path = [entry[1] for entry in headings]
                current = [line]
            else:
                current.append(line)
        if "".join(current).strip():
            sections.append((current_path, "".join(current)))

        index = 0
        for heading_path, section in sections:
            pieces = (
                [section]
                if self._token_count(section) <= self.max_tokens
                else self._split_by_tokens(section)
            )
            for piece in pieces:
                if not piece.strip():
                    continue
                processed.append(
                    _emit_markdown_chunk(self, document, index, piece, heading_path)
                )
                index += 1
    return processed


def _row_lookup(source_id: str) -> dict[tuple[str, str], deque[dict[str, Any]]]:
    store = VectorCreator.create_vectorstore(
        settings.VECTOR_STORE, source_id, settings.EMBEDDINGS_KEY
    )
    rows = sorted(store.get_chunks(), key=lambda row: int(row["doc_id"]))
    lookup: dict[tuple[str, str], deque[dict[str, Any]]] = defaultdict(deque)
    for row in rows:
        metadata = row.get("metadata") or {}
        key = (row.get("text", ""), str(metadata.get("source") or source_id))
        lookup[key].append(row)
    return lookup


def _retrieve(source_id: str, query: str, limit: int, threshold: float):
    # Fail before Dispatcher if embeddings, pgvector or the source index is down.
    preflight = VectorCreator.create_vectorstore(
        settings.VECTOR_STORE, source_id, settings.EMBEDDINGS_KEY
    )
    direct_hits = preflight.search_with_scores(
        query, k=limit, score_threshold=threshold
    )

    retrieval = RetrievalConfig(
        retriever="classic",
        exposure="prefetch",
        chunks=limit,
        score_threshold=threshold,
        rephrase_query=False,
    )
    kwargs = {}
    model_id = get_default_model_id()
    if model_id:
        kwargs["model_id"] = model_id
    dispatcher = Dispatcher(
        source={"active_docs": [source_id], "question": query},
        chat_history=[],
        chunks=limit,
        doc_token_limit=DOC_TOKEN_LIMIT,
        decoded_token={"sub": "local"},
        sources=[{"id": source_id, "retrieval": retrieval}],
        include_scores=True,
        usage_source="chatring_retrieval",
        **kwargs,
    )
    docs = dispatcher.search(query) or []
    if direct_hits and not docs:
        raise ChatRingProviderError(
            "Dispatcher dropped score-qualified pgvector results"
        )
    lookup = _row_lookup(source_id)
    chunks = []
    for rank, doc in enumerate(docs, start=1):
        key = (doc.get("text", ""), str(doc.get("source") or source_id))
        if not lookup[key]:
            raise ChatRingProviderError("retrieved chunk has no pgvector identity")
        row = lookup[key].popleft()
        metadata = row.get("metadata") or {}
        chunks.append(
            {
                "rank": rank,
                "chunk_id": str(row["doc_id"]),
                "text": doc.get("text", ""),
                "title": doc.get("title"),
                "filename": doc.get("filename"),
                "source": doc.get("source"),
                "score": doc.get("score"),
                "score_kind": doc.get("score_kind"),
                "metadata": {
                    key: metadata.get(key)
                    for key in (
                        "chatring_document_id",
                        "chatring_chunk_index",
                        "chatring_content_hash",
                        "chatring_heading_path",
                    )
                    if metadata.get(key) is not None
                },
            }
        )
    return chunks, retrieval.model_dump()


def register_chat_ring_routes(blueprint):
    """Register ChatRing routes on DocsGPT's existing internal blueprint."""

    @blueprint.route("/api/internal/chatring/retrieve", methods=["POST"])
    def chatring_retrieve():
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify({"status": "invalid_request"}), 400
        source_id = str(body.get("source_id") or "").strip()
        query = str(body.get("query") or "").strip()
        try:
            account_id, version_id, binding_digest = _verify_scope(
                "retrieve", source_id
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_id or not query or len(query) > MAX_QUERY_LENGTH:
            return jsonify({"status": "invalid_request"}), 400
        try:
            limit = int(body.get("limit", 5))
            threshold = float(body.get("score_threshold"))
        except (TypeError, ValueError):
            return jsonify({"status": "invalid_request"}), 400
        if not 1 <= limit <= MAX_RESULTS or not 0.0 <= threshold <= 1.0:
            return jsonify({"status": "invalid_request"}), 400
        source = _source(source_id)
        if source is None:
            return jsonify({"status": "not_found"}), 404
        try:
            _verify_source_binding(source, account_id, version_id, binding_digest)
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        try:
            started = time.monotonic()
            chunks, retrieval = _retrieve(source_id, query, limit, threshold)
        except Exception:
            logger.exception("ChatRing DocsGPT retrieval failed")
            return jsonify({"status": "provider_error"}), 503
        return (
            jsonify(
                {
                    "status": "accepted" if chunks else "insufficient_evidence",
                    "source_id": source_id,
                    "retrieval": retrieval,
                    "latency_ms": int((time.monotonic() - started) * 1000),
                    "chunks": chunks,
                }
            ),
            200,
        )

    @blueprint.route("/api/internal/chatring/delete-source", methods=["POST"])
    def chatring_delete_source():
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify({"status": "invalid_request"}), 400
        source_id = str(body.get("source_id") or "").strip()
        try:
            account_id, version_id, binding_digest = _verify_scope(
                "delete_source", source_id
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_id:
            return jsonify({"status": "invalid_request"}), 400
        source = _source(source_id)
        if source is None:
            return jsonify({"status": "already_absent", "source_id": source_id}), 200
        try:
            _verify_source_binding(source, account_id, version_id, binding_digest)
            _delete_source(source)
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except Exception:
            logger.exception("ChatRing DocsGPT source cleanup failed")
            return jsonify({"status": "provider_error"}), 503
        return jsonify({"status": "deleted", "source_id": source_id}), 200


PGVectorStore.search_with_scores = _strict_pgvector_search
MarkdownChunker.chunk = _chatring_markdown_chunk
