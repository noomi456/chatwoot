ARG DOCSGPT_BASE_IMAGE=chatring/docsgpt:upstream-616e6fe9c435bbc6bb472636db6b3ee2b9bcaf66
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
