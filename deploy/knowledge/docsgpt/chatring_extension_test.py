from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
import unittest
from contextlib import nullcontext
from unittest.mock import MagicMock, patch

from flask import Blueprint, Flask

from application.api.internal import chatring_extension as extension
from application.parser.schema.base import Document


class ChatRingExtensionImageTest(unittest.TestCase):
    ACCOUNT_ID = "42"
    VERSION_ID = "17"
    DIGEST = "a" * 64
    SOURCE_ID = "11111111-1111-4111-8111-111111111111"
    INTERNAL_KEY = "ci-internal-key"
    SERVICE_SECRET = "ci-service-secret"

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
        version_id: str | None = None,
        binding_digest: str | None = None,
        timestamp: str | None = None,
    ) -> dict[str, str]:
        timestamp = timestamp or str(int(time.time()))
        source_id = source_id or self.SOURCE_ID
        account_id = account_id or self.ACCOUNT_ID
        version_id = version_id or self.VERSION_ID
        binding_digest = binding_digest or self.DIGEST
        payload = extension._signature_payload(
            timestamp,
            account_id,
            version_id,
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
            "X-ChatRing-Knowledge-Version": version_id,
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
            "name": f"chatring-a{self.ACCOUNT_ID}-v{self.VERSION_ID}-{self.DIGEST}",
        }

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

    def test_maintenance_is_fixed_scope_and_uses_upstream_housekeeping(self):
        body = b"{}"
        headers = self.signed_headers(
            body,
            "cleanup_expired_idempotency",
            source_id=extension.MAINTENANCE_SOURCE_ID,
            account_id="0",
            version_id="0",
            binding_digest=extension.MAINTENANCE_BINDING_DIGEST,
        )
        with patch.object(
            extension,
            "_cleanup_expired_idempotency",
            return_value={"task_dedup_deleted": 4, "webhook_dedup_deleted": 1},
        ) as cleanup:
            response = self.client.post(
                "/api/internal/chatring/maintenance/idempotency",
                data=body,
                headers=headers,
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()["task_dedup_deleted"], 4)
        cleanup.assert_called_once()

        bad_headers = self.signed_headers(
            body,
            "cleanup_expired_idempotency",
            source_id=extension.MAINTENANCE_SOURCE_ID,
            account_id="42",
            version_id="0",
            binding_digest=extension.MAINTENANCE_BINDING_DIGEST,
        )
        response = self.client.post(
            "/api/internal/chatring/maintenance/idempotency",
            data=body,
            headers=bad_headers,
        )
        self.assertEqual(response.status_code, 403)

    def test_markdown_chunking_preserves_content_and_heading_paths(self):
        chunker = MagicMock()
        chunker.max_tokens = 1000
        chunker._token_count.side_effect = lambda text: len(text.split())
        document = Document(
            "# Product\nOne body line.\n## Details\nSecond body line.\n",
            extra_info={"source": "/app/inputs/product.md"},
        )

        chunks = extension._chatring_markdown_chunk(chunker, [document])

        self.assertEqual(len(chunks), 2)
        self.assertEqual(chunks[0].text.count("One body line."), 1)
        self.assertEqual(chunks[1].text.count("Second body line."), 1)
        self.assertEqual(
            chunks[1].extra_info["chatring_heading_path"], "Product > Details"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
