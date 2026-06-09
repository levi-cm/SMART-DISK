FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    smartmontools \
    curl \
    jq \
    coreutils \
    flock

ENV TZ=UTC

WORKDIR /app

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s \
    CMD /scripts/healthcheck.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
