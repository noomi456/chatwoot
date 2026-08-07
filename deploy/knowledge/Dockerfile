ARG DOCSGPT_BASE_IMAGE
FROM ${DOCSGPT_BASE_IMAGE}

ARG DOCSGPT_SOURCE_REPOSITORY
ARG DOCSGPT_SOURCE_COMMIT
ARG DOCSGPT_BASE_DIGEST
ARG CHATRING_SOURCE_COMMIT

LABEL org.opencontainers.image.source="${DOCSGPT_SOURCE_REPOSITORY}" \
      io.chatring.docsgpt.source_commit="${DOCSGPT_SOURCE_COMMIT}" \
      io.chatring.docsgpt.base_digest="${DOCSGPT_BASE_DIGEST}" \
      io.chatring.source_commit="${CHATRING_SOURCE_COMMIT}"

USER root
COPY --chown=appuser:appuser deploy/knowledge/docsgpt/chatring_extension.py /app/application/api/internal/chatring_extension.py
RUN python - <<'PY'
import os
from pathlib import Path

expected_commit = '616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66'
if os.environ.get('DOCSGPT_SOURCE_COMMIT') != expected_commit:
    raise SystemExit('DocsGPT source commit is not approved')
for name in ('DOCSGPT_BASE_DIGEST', 'CHATRING_SOURCE_COMMIT'):
    if not os.environ.get(name):
        raise SystemExit(f'{name} is required')

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
