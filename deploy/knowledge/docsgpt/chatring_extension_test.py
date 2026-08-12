from __future__ import annotations

import hashlib
import hmac
import inspect
import json
import os
import time
import unittest
from contextlib import nullcontext
from unittest.mock import MagicMock, patch

from flask import Blueprint, Flask

from application.api.internal import chatring_extension as extension
from application.parser.schema.base import Document
from application.vectorstore import pgvector as pgvector_module


class ChatRingExtensionImageTest(unittest.TestCase):
    ACCOUNT_ID = "42"
    INDEX_ID = "17"
    DIGEST = "a" * 64
    SOURCE_ID = "11111111-1111-4111-8111-111111111111"
    INTERNAL_KEY = "ci-internal-key"
    SERVICE_SECRET = "ci-service-secret"

    def test_pgvector_correctness_backport_is_pinned_to_the_reviewed_upstream_change(self):
        self.assertEqual(
            extension.PGVECTOR_CORRECTNESS_SOURCE_COMMIT,
            "795e39a6bc40ea499f92290ac19540a842713841",
        )
        self.assertIsNone(pgvector_module.settings.PGVECTOR_IVFFLAT_PROBES)

    @classmethod
    def setUpClass(cls):
        os.environ["INTERNAL_KEY"] = cls.INTERNAL_KEY
        os.environ["CHATRING_SERVICE_SECRET"] = cls.SERVICE_SECRET
        app = Flask(__name__)
        blueprint = Blueprint("chatring_image_test", __name__)
        extension.register_chat_ring_routes(blueprint)
        app.register_blueprint(blueprint)
        app.testing = True
        cls.client = app.test_client()

    def signed_headers(
        self,
        body: bytes,
        operation: str,
        source_id: str | None = None,
        account_id: str | None = None,
        index_id: str | None = None,
        binding_digest: str | None = None,
        timestamp: str | None = None,
    ) -> dict[str, str]:
        timestamp = timestamp or str(int(time.time()))
        source_id = source_id or self.SOURCE_ID
        account_id = account_id or self.ACCOUNT_ID
        index_id = index_id or self.INDEX_ID
        binding_digest = binding_digest or self.DIGEST
        payload = extension._signature_payload(
            timestamp,
            account_id,
            index_id,
            binding_digest,
            operation,
            source_id,
            body,
        )
        signature = hmac.new(
            self.SERVICE_SECRET.encode(), payload, hashlib.sha256
        ).hexdigest()
        return {
            "X-Internal-Key": self.INTERNAL_KEY,
            "X-ChatRing-Timestamp": timestamp,
            "X-ChatRing-Account": account_id,
            "X-ChatRing-Knowledge-Index": index_id,
            "X-ChatRing-Binding-Digest": binding_digest,
            "X-ChatRing-Signature": signature,
            "Content-Type": "application/json",
        }

    def post(self, path: str, body: dict, operation: str, **scope):
        encoded = json.dumps(body, separators=(",", ":")).encode()
        headers = self.signed_headers(encoded, operation, **scope)
        return self.client.post(path, data=encoded, headers=headers)

    def bound_source(self):
        return {
            "id": self.SOURCE_ID,
            "name": f"chatring-a{self.ACCOUNT_ID}-i{self.INDEX_ID}-{self.DIGEST}",
        }

    def test_signed_ingestion_routes_preserve_the_same_source_scope(self):
        source_name = self.bound_source()["name"]
        boundary = "ChatRingTestBoundary"
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="name"\r\n\r\n'
            f"{source_name}\r\n"
            f"--{boundary}--\r\n"
        ).encode()
        headers = self.signed_headers(
            body, "upload_index", source_id=source_name
        )
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        headers["X-ChatRing-Provider-Source"] = source_name
        with patch(
            "application.api.user.sources.upload.UploadFile.post",
            return_value=({"task_id": "task-1", "source_id": self.SOURCE_ID}, 200),
        ):
            response = self.client.post(
                "/api/internal/chatring/upload", data=body, headers=headers
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["task_id"], "task-1")

        headers = self.signed_headers(
            b"", "task_status", source_id=self.SOURCE_ID
        )
        with patch.object(
            extension, "_source", return_value=self.bound_source()
        ), patch(
            "application.api.user.sources.upload.TaskStatus.get",
            return_value=({"status": "SUCCESS"}, 200),
        ):
            response = self.client.get(
                f"/api/internal/chatring/task-status?task_id=task-1&source_id={self.SOURCE_ID}",
                headers=headers,
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["status"], "SUCCESS")

        headers = self.signed_headers(
            b"", "inspect_chunks", source_id=self.SOURCE_ID
        )
        with patch.object(
            extension, "_source", return_value=self.bound_source()
        ), patch(
            "application.api.user.sources.chunks.GetChunks.get",
            return_value=({"chunks": [], "total": 0}, 200),
        ):
            response = self.client.get(
                f"/api/internal/chatring/chunks?source_id={self.SOURCE_ID}&id={self.SOURCE_ID}&page=1&per_page=100",
                headers=headers,
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"chunks": [], "total": 0})

    def test_signed_upload_rejects_a_scope_that_does_not_match_the_source_name(self):
        source_name = self.bound_source()["name"]
        boundary = "ChatRingTestBoundary"
        body = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="name"\r\n\r\n'
            f"{source_name}\r\n"
            f"--{boundary}--\r\n"
        ).encode()
        headers = self.signed_headers(
            body, "upload_index", source_id=source_name, account_id="99"
        )
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        headers["X-ChatRing-Provider-Source"] = source_name

        response = self.client.post(
            "/api/internal/chatring/upload", data=body, headers=headers
        )

        self.assertEqual(response.status_code, 403)

    def test_source_binding_accepts_current_indexes_and_legacy_versions_during_cutover(self):
        extension._verify_source_binding(
            self.bound_source(), self.ACCOUNT_ID, self.INDEX_ID, self.DIGEST
        )
        extension._verify_source_binding(
            {
                "id": self.SOURCE_ID,
                "name": f"chatring-a{self.ACCOUNT_ID}-v{self.INDEX_ID}-{self.DIGEST}",
            },
            self.ACCOUNT_ID,
            self.INDEX_ID,
            self.DIGEST,
        )

        with self.assertRaises(PermissionError):
            extension._verify_source_binding(
                {
                    "id": self.SOURCE_ID,
                    "name": f"chatring-a99-i{self.INDEX_ID}-{self.DIGEST}",
                },
                self.ACCOUNT_ID,
                self.INDEX_ID,
                self.DIGEST,
            )

    def test_scoped_scored_retrieval_and_abstention(self):
        body = {
            "query": "What does the product do?",
            "source_id": self.SOURCE_ID,
            "limit": 4,
            "score_threshold": 0.62,
        }
        chunks = [
            {
                "rank": 1,
                "chunk_id": "chunk-1",
                "text": "Grounded evidence",
                "source": "/app/inputs/home.md",
                "score": 0.84,
                "score_kind": "cosine_similarity",
                "metadata": {"chatring_content_hash": hashlib.sha256(b"Grounded evidence").hexdigest()},
            }
        ]
        with patch.object(extension, "_source", return_value=self.bound_source()), patch.object(
            extension, "_retrieve", return_value=(chunks, {"retriever": "classic"})
        ):
            response = self.post(
                "/api/internal/chatring/retrieve", body, "retrieve"
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["status"], "accepted")
        self.assertEqual(response.get_json()["chunks"][0]["score"], 0.84)

        with patch.object(extension, "_source", return_value=self.bound_source()), patch.object(
            extension, "_retrieve", return_value=([], {"retriever": "classic"})
        ):
            response = self.post(
                "/api/internal/chatring/retrieve", body, "retrieve"
            )
        self.assertEqual(response.get_json()["status"], "insufficient_evidence")

    def test_pgvector_native_search_keeps_threshold_and_stable_identity_contracts(self):
        store = MagicMock()
        store._table_name = "documents"
        store._source_id = self.SOURCE_ID
        connection = MagicMock()
        cursor = connection.cursor.return_value
        cursor.fetchone.return_value = (2,)
        store._get_connection.return_value = connection
        native_results = [
            (extension.VectorDocument("first", {}), 0.82),
            (extension.VectorDocument("second", {}), 0.31),
        ]

        with patch.object(
            extension, "_ORIGINAL_PGVECTOR_SEARCH", return_value=native_results
        ) as native_search:
            results = extension._corrected_pgvector_search(
                store, "question", k=2, score_threshold=0.4
            )

        native_search.assert_called_once_with(
            store, "question", 2, score_threshold=None
        )
        self.assertEqual(
            [(str(document), score) for document, score in results],
            [("first", 0.82)],
        )
        store._embedding.embed_query.assert_not_called()

        metadata = {
            "chatring_document_id": "document-1",
            "chatring_chunk_index": 3,
            "chatring_content_hash": "b" * 64,
        }
        with patch.object(extension, "_ORIGINAL_LABELS_FROM_METADATA", return_value={}):
            first = extension._chatring_labels_from_metadata(
                metadata, "text", self.SOURCE_ID
            )
            second = extension._chatring_labels_from_metadata(
                metadata, "text", self.SOURCE_ID
            )
        self.assertEqual(
            first["chatring_provider_chunk_id"],
            second["chatring_provider_chunk_id"],
        )
        self.assertEqual(len(first["chatring_provider_chunk_id"]), 64)

        with patch.object(
            extension,
            "_ORIGINAL_LABELS_FROM_METADATA",
            return_value={"chatring_provider_chunk_id": "legacy-row-id"},
        ):
            incomplete = extension._chatring_labels_from_metadata(
                {"chatring_provider_chunk_id": "legacy-row-id"},
                "text",
                self.SOURCE_ID,
            )
        self.assertNotIn("chatring_provider_chunk_id", incomplete)

    def test_pgvector_under_return_uses_exact_search_and_dependency_failure_is_not_abstention(self):
        store = MagicMock()
        store._table_name = "documents"
        store._vector_column = "embedding"
        store._text_column = "text"
        store._metadata_column = "metadata"
        store._source_id = self.SOURCE_ID
        store._embedding.embed_query.return_value = [0.1, 0.2]
        connection = MagicMock()
        cursor = connection.cursor.return_value
        cursor.fetchone.return_value = (2,)
        cursor.fetchall.return_value = [
            ("first", {"chatring_document_id": "d1"}, 0.1),
            ("second", {"chatring_document_id": "d2"}, 0.2),
        ]
        store._get_connection.return_value = connection

        with patch.object(
            extension,
            "_ORIGINAL_PGVECTOR_SEARCH",
            return_value=[(extension.VectorDocument("first", {}), 0.9)],
        ):
            results = extension._corrected_pgvector_search(store, "question", k=2)

        self.assertEqual(
            [(str(document), score) for document, score in results],
            [("first", 0.9), ("second", 0.8)],
        )
        store._embedding.embed_query.assert_called_once_with("question")
        self.assertTrue(
            any(
                "enable_indexscan = off" in call.args[0]
                for call in cursor.execute.call_args_list
            )
        )

        cursor.execute.side_effect = RuntimeError("database unavailable")
        with patch.object(extension, "_ORIGINAL_PGVECTOR_SEARCH", return_value=[]):
            with self.assertRaises(extension.ChatRingProviderError):
                extension._corrected_pgvector_search(store, "question", k=2)

    def test_pgvector_prevents_automatic_ivfflat_and_raises_legacy_probes(self):
        ensure_source = inspect.getsource(extension.PGVectorStore._ensure_table_exists)
        self.assertNotIn("USING ivfflat", ensure_source)

        store = object.__new__(extension.PGVectorStore)
        store._table_name = "documents"
        pgvector_module._IVFFLAT_LISTS_CACHE.clear()
        probe_connection = MagicMock()
        probe_cursor = probe_connection.cursor.return_value.__enter__.return_value
        index_definition = (
            "CREATE INDEX documents_embedding_idx ON documents "
            "USING ivfflat (embedding vector_cosine_ops) WITH (lists='100')"
        )
        probe_cursor.fetchone.side_effect = [None, (index_definition,)]
        self.assertIsNone(store._ivfflat_lists(probe_connection))
        self.assertEqual(store._ivfflat_lists(probe_connection), 100)
        with patch.object(pgvector_module.settings, "PGVECTOR_IVFFLAT_PROBES", None):
            store._apply_ivfflat_probes(probe_connection)
        self.assertTrue(
            any(
                call.args[0] == "SET ivfflat.probes = 10;"
                for call in probe_cursor.execute.call_args_list
            )
        )

    def test_authentication_scope_expiry_and_provider_failure(self):
        body = {
            "query": "Question",
            "source_id": self.SOURCE_ID,
            "limit": 4,
            "score_threshold": 0.62,
        }
        encoded = json.dumps(body, separators=(",", ":")).encode()
        headers = self.signed_headers(encoded, "retrieve")
        headers["X-Internal-Key"] = "wrong"
        response = self.client.post(
            "/api/internal/chatring/retrieve", data=encoded, headers=headers
        )
        self.assertEqual(response.status_code, 403)

        with patch.object(extension, "_source", return_value=self.bound_source()):
            response = self.post(
                "/api/internal/chatring/retrieve",
                body,
                "retrieve",
                account_id="99",
            )
        self.assertEqual(response.status_code, 403)

        headers = self.signed_headers(
            encoded, "retrieve", timestamp=str(int(time.time()) - 3600)
        )
        response = self.client.post(
            "/api/internal/chatring/retrieve", data=encoded, headers=headers
        )
        self.assertEqual(response.status_code, 403)

        with patch.object(extension, "_source", return_value=self.bound_source()), patch.object(
            extension, "_retrieve", side_effect=RuntimeError("dependency down")
        ):
            response = self.post(
                "/api/internal/chatring/retrieve", body, "retrieve"
            )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.get_json()["status"], "provider_error")

    def test_source_deletion_is_idempotent_and_cleans_progress(self):
        body = {"source_id": self.SOURCE_ID}
        with patch.object(extension, "_source", return_value=self.bound_source()), patch.object(
            extension, "_delete_source"
        ) as delete_source:
            response = self.post(
                "/api/internal/chatring/delete-source", body, "delete_source"
            )
        self.assertEqual(response.get_json()["status"], "deleted")
        delete_source.assert_called_once()

        with patch.object(extension, "_source", return_value=None), patch.object(
            extension, "_delete_ingest_progress"
        ) as delete_progress:
            response = self.post(
                "/api/internal/chatring/delete-source", body, "delete_source"
            )
        self.assertEqual(response.get_json()["status"], "already_absent")
        delete_progress.assert_called_once_with(self.SOURCE_ID)

        store = MagicMock()
        progress = MagicMock()
        sources = MagicMock()
        with patch.object(extension.VectorCreator, "create_vectorstore", return_value=store), patch.object(
            extension, "db_session", return_value=nullcontext(MagicMock())
        ), patch.object(
            extension, "IngestChunkProgressRepository", return_value=progress
        ), patch.object(extension, "SourcesRepository", return_value=sources):
            extension._delete_source(self.bound_source())
        progress.delete.assert_called_once_with(self.SOURCE_ID)
        sources.delete.assert_called_once_with(self.SOURCE_ID, "local")

    def test_markdown_chunking_preserves_content_and_heading_paths(self):
        chunker = MagicMock()
        chunker.max_tokens = 1000
        chunker.min_tokens = 6
        chunker._token_count.side_effect = lambda text: len(text.split())
        document = Document(
            "# Product\nOne body line.\n## Details\nSecond body line.\n",
            extra_info={"source": "/app/inputs/product.md"},
        )

        chunks = extension._chatring_markdown_chunk(chunker, [document])

        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].text.count("One body line."), 1)
        self.assertEqual(chunks[0].text.count("Second body line."), 1)
        self.assertEqual(
            chunks[0].extra_info["chatring_heading_path"], "Product"
        )

    def test_markdown_chunking_does_not_merge_unheaded_preamble_into_a_heading(self):
        chunker = MagicMock()
        chunker.max_tokens = 1000
        chunker.min_tokens = 20
        chunker._token_count.side_effect = lambda text: len(text.split())
        document = Document(
            "Short preamble.\n# Operations\nRotate keys every week.\n",
            extra_info={"source": "/app/inputs/operations.md"},
        )

        chunks = extension._chatring_markdown_chunk(chunker, [document])

        self.assertEqual(len(chunks), 2)
        self.assertEqual(chunks[0].extra_info["chatring_heading_path"], "")
        self.assertEqual(chunks[1].extra_info["chatring_heading_path"], "Operations")


if __name__ == "__main__":
    unittest.main(verbosity=2)
