ARG DOCSGPT_BASE_IMAGE
FROM ${DOCSGPT_BASE_IMAGE}

ARG DOCSGPT_SOURCE_REPOSITORY
ARG DOCSGPT_SOURCE_COMMIT
ARG DOCSGPT_BASE_DIGEST
ARG CHATRING_SOURCE_COMMIT

LABEL org.opencontainers.image.source="${DOCSGPT_SOURCE_REPOSITORY}" \
      io.chatring.docsgpt.source_commit="${DOCSGPT_SOURCE_COMMIT}" \
      io.chatring.docsgpt.pgvector_backport="795e39a6bc40ea499f92290ac19540a842713841" \
      io.chatring.docsgpt.base_digest="${DOCSGPT_BASE_DIGEST}" \
      io.chatring.source_commit="${CHATRING_SOURCE_COMMIT}"

USER root
COPY --chown=appuser:appuser deploy/knowledge/docsgpt/upstream/pgvector.py /app/application/vectorstore/pgvector.py
COPY --chown=appuser:appuser deploy/knowledge/docsgpt/chatring_extension.py /app/application/api/internal/chatring_extension.py
RUN python - <<'PY'
import hashlib
import os
from pathlib import Path

expected_commit = '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'
if os.environ.get('DOCSGPT_SOURCE_COMMIT') != expected_commit:
    raise SystemExit('DocsGPT source commit is not approved')
for name in ('DOCSGPT_BASE_DIGEST', 'CHATRING_SOURCE_COMMIT'):
    if not os.environ.get(name):
        raise SystemExit(f'{name} is required')

pgvector_path = Path('/app/application/vectorstore/pgvector.py')
expected_pgvector_sha256 = '34e9d74518cfa713b06ff8f437f4d6cd58325f28c54bcc32c6cc349225e59d8c'
if hashlib.sha256(pgvector_path.read_bytes()).hexdigest() != expected_pgvector_sha256:
    raise SystemExit('DocsGPT pgvector correctness backport does not match reviewed upstream source')

settings_path = Path('/app/application/core/settings.py')
settings_source = settings_path.read_text(encoding='utf-8')
probe_setting = '    PGVECTOR_IVFFLAT_PROBES: Optional[int] = None\n'
if probe_setting not in settings_source:
    connection_setting = '    PGVECTOR_CONNECTION_STRING: Optional[str] = None\n'
    if settings_source.count(connection_setting) != 1:
        raise SystemExit('DocsGPT pgvector settings contract changed')
    settings_source = settings_source.replace(
        connection_setting,
        connection_setting
        + '    # IVFFlat probes for vector search. None derives sqrt(lists).\n'
        + probe_setting,
    )
    settings_path.write_text(settings_source, encoding='utf-8')

path = Path('/app/application/api/internal/routes.py')
marker = 'register_chat_ring_routes(internal)'
source = path.read_text(encoding='utf-8')
if marker not in source:
    source += (
        '\nfrom application.api.internal.chatring_extension import '
        'register_chat_ring_routes\n'
        'register_chat_ring_routes(internal)\n'
    )
    path.write_text(source, encoding='utf-8')

app_path = Path('/app/application/app.py')
app_source = app_path.read_text(encoding='utf-8')
token_log = '    print(f"Generated Simple JWT Token: {SIMPLE_JWT_TOKEN}")'
if app_source.count(token_log) != 1:
    raise SystemExit('DocsGPT JWT startup-log contract changed')
app_path.write_text(
    app_source.replace(token_log, '    print("Simple JWT authentication initialized")'),
    encoding='utf-8',
)
PY
USER appuser
