FROM alpine:3.22

ARG WGCF_VERSION=2.3.1
ARG TARGETARCH

RUN apk add --no-cache \
        bash curl iproute2 iptables conntrack-tools \
        wireguard-tools-wg wireguard-go \
        dnsmasq tini su-exec \
    && ARCH="${TARGETARCH:-$(uname -m)}" \
    && case "$ARCH" in \
         amd64|x86_64)   WGCF_ARCH=amd64 ;; \
         arm64|aarch64)  WGCF_ARCH=arm64 ;; \
         arm|armv7l)     WGCF_ARCH=armv7 ;; \
         386|i686)       WGCF_ARCH=386 ;; \
         *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/wgcf \
         "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WGCF_ARCH}" \
    && chmod +x /usr/local/bin/wgcf \
    && adduser -D -H -u 9999 -s /sbin/nologin warpprobe

COPY gateway.sh /usr/local/bin/gateway.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/gateway.sh /usr/local/bin/healthcheck.sh

VOLUME /data

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/gateway.sh"]
