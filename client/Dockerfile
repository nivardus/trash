FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
WORKDIR /app

# build/server/<amd64|arm64>/ holds the pre-exported binary + pck for the target arch.
COPY build/server/${TARGETARCH}/ /app/
RUN chmod +x /app/trash_server

EXPOSE 9000
# stdbuf forces line-buffered stdout/stderr so server logs stream live (Godot
# block-buffers when stdout is not a TTY). stdbuf ships with debian's coreutils.
ENTRYPOINT ["stdbuf", "-oL", "-eL", "/app/trash_server", "--headless"]
