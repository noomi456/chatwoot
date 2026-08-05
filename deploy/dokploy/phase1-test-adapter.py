"""Disposable Phase 1 AgentBot boundary probe. Never deploy as a product service."""

import hashlib
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"].encode()
BOT_TOKEN = os.environ["BOT_TOKEN"]
AGENT_ID = int(os.environ["AGENT_ID"])
CORE_URL = os.environ["CORE_URL"].rstrip("/")
EVENT_LOG = os.environ.get("EVENT_LOG", "/data/events.jsonl")
REPLAY_CAPTURE = os.environ.get("REPLAY_CAPTURE", "/data/replay-capture.json")
PORT = int(os.environ.get("PORT", "8080"))

seen_deliveries: set[str] = set()
human_only_conversations: set[int] = set()
state_lock = threading.Lock()


def record(action: str, delivery: str, conversation_id: int | None = None) -> None:
    entry = {
        "timestamp": int(time.time()),
        "delivery": delivery,
        "conversation_id": conversation_id,
        "action": action,
    }
    with open(EVENT_LOG, "a", encoding="utf-8") as log:
        log.write(json.dumps(entry, separators=(",", ":")) + "\n")


def core_post(path: str, payload: dict) -> None:
    request = urllib.request.Request(
        f"{CORE_URL}{path}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "api_access_token": BOT_TOKEN},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            if response.status != 200:
                raise RuntimeError(f"ChatRing API returned {response.status}")
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"ChatRing API returned {error.code}") from error


class Handler(BaseHTTPRequestHandler):
    server_version = "ChatRingPhase1Adapter/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_status(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": status}).encode())

    def do_GET(self) -> None:
        self.send_status(200 if self.path == "/health" else 404)

    def do_POST(self) -> None:
        if self.path != "/phase1-adapter":
            self.send_status(404)
            return

        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        delivery = self.headers.get("X-Chatwoot-Delivery", "")
        timestamp = self.headers.get("X-Chatwoot-Timestamp", "")
        signature = self.headers.get("X-Chatwoot-Signature", "")
        expected = "sha256=" + hmac.new(
            WEBHOOK_SECRET, timestamp.encode() + b"." + body, hashlib.sha256
        ).hexdigest()

        if not delivery or not timestamp or not hmac.compare_digest(signature, expected):
            record("rejected_signature", delivery or "missing")
            self.send_status(401)
            return

        try:
            timestamp_age = abs(int(time.time()) - int(timestamp))
        except ValueError:
            record("rejected_timestamp", delivery)
            self.send_status(401)
            return

        if timestamp_age > 300:
            record("rejected_timestamp", delivery)
            self.send_status(401)
            return

        payload = json.loads(body)
        if (
            payload.get("event") == "message_created"
            and payload.get("message_type") == "incoming"
            and not os.path.exists(REPLAY_CAPTURE)
        ):
            with open(REPLAY_CAPTURE, "w", encoding="utf-8") as capture:
                json.dump(
                    {
                        "delivery": delivery,
                        "timestamp": timestamp,
                        "signature": signature,
                        "body": body.decode(),
                    },
                    capture,
                )

        with state_lock:
            if delivery in seen_deliveries:
                record("ignored_duplicate", delivery)
                self.send_status(200)
                return
            seen_deliveries.add(delivery)

        event = payload.get("event")
        conversation_id = payload.get("conversation", {}).get("id")
        account_id = payload.get("account", {}).get("id")

        if event != "message_created" or payload.get("message_type") != "incoming" or payload.get("private"):
            record("ignored_non_incoming", delivery, conversation_id)
            self.send_status(200)
            return

        with state_lock:
            if conversation_id in human_only_conversations:
                record("ignored_human_only", delivery, conversation_id)
                self.send_status(200)
                return

        content = payload.get("content", "")
        if content == "Phase 1 request human":
            core_post(
                f"/api/v1/accounts/{account_id}/conversations/{conversation_id}/assignments",
                {"assignee_id": AGENT_ID},
            )
            with state_lock:
                human_only_conversations.add(conversation_id)
            record("handoff_to_human", delivery, conversation_id)
        else:
            core_post(
                f"/api/v1/accounts/{account_id}/conversations/{conversation_id}/messages",
                {"content": "Phase 1 signed webhook reply"},
            )
            record("replied", delivery, conversation_id)

        self.send_status(200)


if __name__ == "__main__":
    os.makedirs(os.path.dirname(EVENT_LOG), exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
