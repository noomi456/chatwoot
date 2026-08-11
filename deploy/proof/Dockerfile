ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CHATRING_SOURCE_COMMIT
ARG CHATRING_PROOF_COMMIT
ARG CHATRING_PROOF_MANIFEST

COPY deploy/proof/llm_proxy.rb /app/deploy/proof/llm_proxy.rb
COPY deploy/proof/log_scan.rb /app/deploy/proof/log_scan.rb
COPY deploy/proof/web_widget_driver.rb /app/deploy/proof/web_widget_driver.rb

RUN test "$(cat /app/.git_sha)" = "${CHATRING_SOURCE_COMMIT}" \
  && test "$(grep -c '^  PUBLIC_AI_RELEASE_READY = false$' /app/app/services/chat_ring/assistant_spike.rb)" = "1" \
  && sed -i 's/^  PUBLIC_AI_RELEASE_READY = false$/  PUBLIC_AI_RELEASE_READY = true/' \
       /app/app/services/chat_ring/assistant_spike.rb \
  && test "$(grep -c '^  EXTERNAL_RUNTIME_ENABLED = false$' /app/app/services/chat_ring/assistant_spike.rb)" = "1"

LABEL io.chatring.proof.base_commit="${CHATRING_SOURCE_COMMIT}" \
      io.chatring.proof.commit="${CHATRING_PROOF_COMMIT}" \
      io.chatring.proof.manifest="${CHATRING_PROOF_MANIFEST}" \
      io.chatring.proof.scope="isolated-web-widget-section-13"
