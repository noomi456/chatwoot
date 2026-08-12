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
from pathlib import Path
from typing import Any

from flask import jsonify, request

from application.core.model_utils import get_default_model_id
from application.core.settings import settings
from application.parser.chunking_strategies import MarkdownChunker
from application.parser.file.markdown_parser import MarkdownParser
from application.parser.schema.base import Document
from application.retriever import classic_rag as classic_rag_module
from application.retriever.dispatcher import Dispatcher
from application.storage.db.repositories.sources import SourcesRepository
from application.storage.db.repositories.ingest_chunk_progress import (
    IngestChunkProgressRepository,
)
from application.storage.db.session import db_readonly, db_session
from application.storage.db.source_config import RetrievalConfig
from application.storage.storage_creator import StorageCreator
from application.vectorstore.document_class import Document as VectorDocument
from application.vectorstore.pgvector import PGVectorStore
from application.vectorstore.vector_creator import VectorCreator


MAX_QUERY_LENGTH = 2000
DEFAULT_EVIDENCE_LIMIT = 8
MAX_RESULTS = 20
MAX_CLOCK_SKEW_SECONDS = 90
DOC_TOKEN_LIMIT = 50000
PGVECTOR_CORRECTNESS_SOURCE_COMMIT = "795e39a6bc40ea499f92290ac19540a842713841"
_HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
_SOURCE_BINDING = re.compile(
    # ``v`` is accepted only for provider sources created before the hidden
    # KnowledgeIndex rename. New uploads use ``i``. Both bind the same
    # immutable database id and digest during the coordinated cutover.
    r"^chatring-a(?P<account>\d+)-(?:i|v)(?P<index>\d+)-(?P<digest>[0-9a-f]{64})$"
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
    knowledge_index_id: str,
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
            knowledge_index_id,
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
    index_id = request.headers.get("X-ChatRing-Knowledge-Index", "")
    binding_digest = request.headers.get("X-ChatRing-Binding-Digest", "")
    provided = request.headers.get("X-ChatRing-Signature", "")
    if not provided_internal_key or not hmac.compare_digest(
        _internal_key(), provided_internal_key
    ):
        raise PermissionError("invalid internal credential")
    if not all((timestamp, account_id, index_id, binding_digest, provided)):
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
            index_id,
            binding_digest,
            operation,
            source_id,
            request.get_data(cache=True),
        ),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(expected, provided):
        raise PermissionError("invalid scoped credential")
    return account_id, index_id, binding_digest


def _source(source_id: str) -> dict[str, Any] | None:
    with db_readonly() as connection:
        return SourcesRepository(connection).get(source_id, "local")


def _verify_source_binding(
    source: dict[str, Any], account_id: str, index_id: str, binding_digest: str
) -> None:
    match = _SOURCE_BINDING.fullmatch(str(source.get("name") or ""))
    if match is None or match.groupdict() != {
        "account": account_id,
        "index": index_id,
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
        IngestChunkProgressRepository(connection).delete(source_id)
        SourcesRepository(connection).delete(source_id, "local")


def _delete_ingest_progress(source_id: str) -> None:
    with db_session() as connection:
        IngestChunkProgressRepository(connection).delete(source_id)


_ORIGINAL_PGVECTOR_SEARCH = PGVectorStore.search_with_scores


def _pgvector_exact_fallback(self, question: str, k: int, ann_results: list):
    """Port upstream's filtered-ANN completeness check, failing closed."""
    connection = self._get_connection()
    try:
        # The pinned native method catches SQL failures without rolling back.
        # Ending its read transaction also clears that failed state before the
        # authoritative completeness check.
        connection.rollback()
    except Exception:
        pass
    cursor = connection.cursor()
    try:
        cursor.execute(
            f"SELECT count(*) FROM {self._table_name} WHERE source_id = %s",
            (self._source_id,),
        )
        available = cursor.fetchone()[0]
        if len(ann_results) >= min(k, available):
            return ann_results

        query_vector = self._embedding.embed_query(question)
        cursor.execute("SET LOCAL enable_indexscan = off;")
        cursor.execute("SET LOCAL enable_bitmapscan = off;")
        cursor.execute(
            f"""
            SELECT {self._text_column}, {self._metadata_column},
                   ({self._vector_column} <=> %s::vector) AS distance
            FROM {self._table_name}
            WHERE source_id = %s
            ORDER BY {self._vector_column} <=> %s::vector
            LIMIT %s;
            """,
            (query_vector, self._source_id, query_vector, k),
        )
        exact_rows = cursor.fetchall()
        if len(exact_rows) < len(ann_results):
            return ann_results
        if len(exact_rows) > len(ann_results):
            logger.info(
                "Vector index under-returned for source %s (%d of %d); used exact search instead.",
                self._source_id,
                len(ann_results),
                min(k, available),
            )
        return [
            (VectorDocument(text, dict(metadata or {})), 1.0 - float(distance))
            for text, metadata, distance in exact_rows
        ]
    except Exception as exc:
        connection.rollback()
        raise ChatRingProviderError("pgvector exact-search fallback failed") from exc
    finally:
        try:
            cursor.execute("RESET enable_indexscan;")
            cursor.execute("RESET enable_bitmapscan;")
        except Exception:
            pass
        cursor.close()


def _corrected_pgvector_search(self, question, k=2, *args, score_threshold=None, **kwargs):
    """Delegate native retrieval, then add upstream completeness and strictness."""
    native_results = _ORIGINAL_PGVECTOR_SEARCH(
        self, question, k, *args, score_threshold=None, **kwargs
    )
    results = _pgvector_exact_fallback(self, question, k, native_results)
    accepted = []
    for document, score in results:
        if score is None or not math.isfinite(float(score)):
            raise ChatRingProviderError("pgvector returned a non-finite score")
        resolved_score = float(score)
        if score_threshold is None or resolved_score >= float(score_threshold):
            accepted.append((document, resolved_score))
    return accepted


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
                heading_text = re.sub(r"\s+", " ", match.group(2)).strip()
                headings.append((level, heading_text))
                current_path = [entry[1] for entry in headings]
                current = [line]
            else:
                current.append(line)
        if "".join(current).strip():
            sections.append((current_path, "".join(current)))

        raw_pieces: list[tuple[list[str], str]] = []
        for heading_path, section in sections:
            pieces = (
                [section]
                if self._token_count(section) <= self.max_tokens
                else self._split_by_tokens(section)
            )
            for piece in pieces:
                if not piece.strip():
                    continue
                raw_pieces.append((heading_path, piece))

        minimum = max(0, int(getattr(self, "min_tokens", 0) or 0))
        coalesced: list[tuple[list[str], str]] = []
        for heading_path, piece in raw_pieces:
            if not coalesced:
                coalesced.append((heading_path, piece))
                continue

            previous_path, previous_piece = coalesced[-1]
            combined = previous_piece.rstrip() + "\n\n" + piece.lstrip()
            common_path = []
            for left, right in zip(previous_path, heading_path):
                if left != right:
                    break
                common_path.append(left)
            if (
                minimum > 0
                and (
                    self._token_count(previous_piece) < minimum
                    or self._token_count(piece) < minimum
                )
                and self._token_count(combined) <= self.max_tokens
                and (previous_path == heading_path or common_path)
            ):
                coalesced[-1] = (common_path, combined)
            else:
                coalesced.append((heading_path, piece))

        for index, (heading_path, piece) in enumerate(coalesced):
            processed.append(
                _emit_markdown_chunk(self, document, index, piece, heading_path)
            )
    return processed


def _chatring_markdown_parse_file(
    self: MarkdownParser, filepath: Path, errors: str = "ignore"
) -> str:
    """Keep accepted ChatRing Markdown intact for structure-aware chunking.

    DocsGPT's default MarkdownParser removes ``#`` markers and emits one flat
    document per heading before the configured MarkdownChunker runs. That
    makes heading hierarchy unrecoverable. ChatRing has already normalized
    and approved these Markdown snapshots, so the dedicated knowledge worker
    must pass the original document to the structure-aware chunker.
    """
    return Path(filepath).read_text(encoding="utf-8", errors=errors)


_ORIGINAL_LABELS_FROM_METADATA = classic_rag_module.labels_from_metadata
_PROVENANCE_KEYS = (
    "chatring_provider_chunk_id",
    "chatring_document_id",
    "chatring_chunk_index",
    "chatring_content_hash",
    "chatring_heading_path",
)


def _chatring_labels_from_metadata(
    metadata: dict[str, Any], page_content: str, vectorstore_id: str
) -> dict[str, Any]:
    """Keep stable provenance on the scored documents returned by Dispatcher."""
    values = dict(metadata)
    values.pop("chatring_provider_chunk_id", None)
    identity = (
        values.get("chatring_document_id"),
        values.get("chatring_chunk_index"),
        values.get("chatring_content_hash"),
    )
    if all(value is not None for value in identity):
        values["chatring_provider_chunk_id"] = hashlib.sha256(
            "\n".join(str(value) for value in identity).encode("utf-8")
        ).hexdigest()
    labels = _ORIGINAL_LABELS_FROM_METADATA(metadata, page_content, vectorstore_id)
    labels.pop("chatring_provider_chunk_id", None)
    labels.update(
        {key: values[key] for key in _PROVENANCE_KEYS if values.get(key) is not None}
    )
    return labels


def _retrieve(source_id: str, query: str, limit: int):
    retrieval = RetrievalConfig(
        retriever="classic",
        exposure="prefetch",
        chunks=limit,
        score_threshold=None,
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
    if not docs:
        # ClassicRAG intentionally catches vector-store failures. Probe only an
        # empty result so dependency failure remains distinct from no evidence
        # without doubling every successful embedding and pgvector search.
        store = VectorCreator.create_vectorstore(
            settings.VECTOR_STORE, source_id, settings.EMBEDDINGS_KEY
        )
        direct_hits = store.search_with_scores(
            query, k=limit, score_threshold=None
        )
        if direct_hits:
            raise ChatRingProviderError(
                "Dispatcher dropped score-qualified pgvector results"
            )
        return [], retrieval.model_dump()

    chunks = []
    for rank, doc in enumerate(docs, start=1):
        chunk_id = doc.get("chatring_provider_chunk_id")
        if chunk_id is None:
            raise ChatRingProviderError("retrieved chunk has no stable provenance identity")
        chunks.append(
            {
                "rank": rank,
                "chunk_id": str(chunk_id),
                "text": doc.get("text", ""),
                "title": doc.get("title"),
                "filename": doc.get("filename"),
                "source": doc.get("source"),
                "score": doc.get("score"),
                "score_kind": doc.get("score_kind"),
                "metadata": {
                    key: doc.get(key)
                    for key in (
                        "chatring_document_id",
                        "chatring_chunk_index",
                        "chatring_content_hash",
                        "chatring_heading_path",
                    )
                    if doc.get(key) is not None
                },
            }
        )
    return chunks, retrieval.model_dump()


def register_chat_ring_routes(blueprint):
    """Register ChatRing routes on DocsGPT's existing internal blueprint."""

    @blueprint.route("/api/internal/chatring/upload", methods=["POST"])
    def chatring_upload():
        source_name = request.headers.get("X-ChatRing-Provider-Source", "").strip()
        try:
            account_id, index_id, binding_digest = _verify_scope(
                "upload_index", source_name
            )
            _verify_source_binding(
                {"name": source_name}, account_id, index_id, binding_digest
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_name or request.form.get("name") != source_name:
            return jsonify({"status": "invalid_request"}), 400
        try:
            from application.api.user.sources.upload import UploadFile

            request.decoded_token = {"sub": "local"}
            return UploadFile().post()
        except Exception:
            logger.exception("ChatRing DocsGPT upload failed")
            return jsonify({"status": "provider_error"}), 503

    @blueprint.route("/api/internal/chatring/task-status", methods=["GET"])
    def chatring_task_status():
        source_id = str(request.args.get("source_id") or "").strip()
        try:
            account_id, index_id, binding_digest = _verify_scope(
                "task_status", source_id
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_id or not request.args.get("task_id"):
            return jsonify({"status": "invalid_request"}), 400
        source = _source(source_id)
        if source is not None:
            try:
                _verify_source_binding(source, account_id, index_id, binding_digest)
            except PermissionError:
                return jsonify({"status": "forbidden"}), 403
        try:
            from application.api.user.sources.upload import TaskStatus

            request.decoded_token = {"sub": "local"}
            return TaskStatus().get()
        except Exception:
            logger.exception("ChatRing DocsGPT task-status inspection failed")
            return jsonify({"status": "provider_error"}), 503

    @blueprint.route("/api/internal/chatring/chunks", methods=["GET"])
    def chatring_chunks():
        source_id = str(request.args.get("source_id") or "").strip()
        try:
            account_id, index_id, binding_digest = _verify_scope(
                "inspect_chunks", source_id
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_id or str(request.args.get("id") or "").strip() != source_id:
            return jsonify({"status": "invalid_request"}), 400
        source = _source(source_id)
        if source is None:
            return jsonify({"status": "not_found"}), 404
        try:
            _verify_source_binding(source, account_id, index_id, binding_digest)
            from application.api.user.sources.chunks import GetChunks

            request.decoded_token = {"sub": "local"}
            return GetChunks().get()
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except Exception:
            logger.exception("ChatRing DocsGPT chunk inspection failed")
            return jsonify({"status": "provider_error"}), 503

    @blueprint.route("/api/internal/chatring/retrieve", methods=["POST"])
    def chatring_retrieve():
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify({"status": "invalid_request"}), 400
        source_id = str(body.get("source_id") or "").strip()
        query = str(body.get("query") or "").strip()
        try:
            account_id, index_id, binding_digest = _verify_scope(
                "retrieve", source_id
            )
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except ChatRingProviderError:
            return jsonify({"status": "provider_error"}), 503
        if not source_id or not query or len(query) > MAX_QUERY_LENGTH:
            return jsonify({"status": "invalid_request"}), 400
        try:
            limit = int(body.get("limit", DEFAULT_EVIDENCE_LIMIT))
        except (TypeError, ValueError):
            return jsonify({"status": "invalid_request"}), 400
        if not 1 <= limit <= MAX_RESULTS:
            return jsonify({"status": "invalid_request"}), 400
        source = _source(source_id)
        if source is None:
            return jsonify({"status": "not_found"}), 404
        try:
            _verify_source_binding(source, account_id, index_id, binding_digest)
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        try:
            started = time.monotonic()
            chunks, retrieval = _retrieve(source_id, query, limit)
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
            account_id, index_id, binding_digest = _verify_scope(
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
            try:
                _delete_ingest_progress(source_id)
            except Exception:
                logger.exception("ChatRing DocsGPT orphan ingest-progress cleanup failed")
                return jsonify({"status": "provider_error"}), 503
            return jsonify({"status": "already_absent", "source_id": source_id}), 200
        try:
            _verify_source_binding(source, account_id, index_id, binding_digest)
            _delete_source(source)
        except PermissionError:
            return jsonify({"status": "forbidden"}), 403
        except Exception:
            logger.exception("ChatRing DocsGPT source cleanup failed")
            return jsonify({"status": "provider_error"}), 503
        return jsonify({"status": "deleted", "source_id": source_id}), 200

PGVectorStore.search_with_scores = _corrected_pgvector_search
classic_rag_module.labels_from_metadata = _chatring_labels_from_metadata
MarkdownParser.parse_file = _chatring_markdown_parse_file
MarkdownChunker.chunk = _chatring_markdown_chunk
