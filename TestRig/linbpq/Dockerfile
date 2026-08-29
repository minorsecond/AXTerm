# LinBPQ (G8BPQ) — the canonical ARM build, run under Docker Desktop's
# arm/v7 support. Downloaded from the official site at build time; the
# licence permits use but not redistribution, so the binary is never
# committed to this repo.
FROM --platform=linux/arm/v7 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libasound2 zlib1g \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/bpq \
    && curl -fsSL -o /opt/bpq/linbpq \
        https://www.cantab.net/users/john.wiseman/Downloads/Beta/pilinbpq \
    && chmod +x /opt/bpq/linbpq
WORKDIR /opt/bpq
COPY bpq32.cfg /opt/bpq/bpq32.cfg
EXPOSE 8011
CMD ["/opt/bpq/linbpq"]
