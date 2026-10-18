# Wraith studio — Kiro Agent Server inside a Lambda MicroVM (ported from shadow_corp).
#
# Built by `aws lambda-microvms create-microvm-image` on top of the managed
# AL2023 MicroVM base image (arm64). The build context is the zip produced by
# microvm/build.sh: this file, shim/, and kas/ (the pinned @kiro/agent bundle
# copied from a local Kiro CLI install — not committed).
FROM public.ecr.aws/lambda/microvms:al2023-minimal

ARG BUN_VERSION=1.4.2

RUN microdnf install -y tar gzip unzip git shadow-utils findutils procps-ng \
 && microdnf clean all

RUN curl -fsSL -o /tmp/bun.zip \
      https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-aarch64.zip \
 && unzip -q /tmp/bun.zip -d /tmp \
 && install -m755 /tmp/bun-linux-aarch64/bun /usr/local/bin/bun \
 && rm -rf /tmp/bun* \
 && bun --version

RUN useradd -m -d /home/operative -s /bin/bash operative \
 && mkdir -p /work && chown operative:operative /work

# /opt/kas/VERSION is the pinned bundle (microvm/KAS_VERSION); the shim reports it
COPY --chown=operative:operative kas /opt/kas
COPY --chown=operative:operative shim /opt/shim

USER operative
ENV HOME=/home/operative \
    ACP_WS_PORT=8082 \
    WORK_DIR=/work \
    OPERATIVE_HOME=/home/operative \
    KAS_ENTRY=/opt/kas/node_modules/@kiro/agent/dist/server/acp-server.js
WORKDIR /work

EXPOSE 8080 8082
CMD ["bun", "/opt/shim/server.ts"]
