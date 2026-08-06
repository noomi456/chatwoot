ARG DOCSGPT_BASE_IMAGE
FROM ${DOCSGPT_BASE_IMAGE}

USER root
COPY --chown=appuser:appuser deploy/knowledge/docsgpt/chatring_extension.py /app/application/api/internal/chatring_extension.py
RUN python - <<'PY'
from pathlib import Path

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
PY
USER appuser
