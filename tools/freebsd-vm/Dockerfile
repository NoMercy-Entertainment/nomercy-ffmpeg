FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl openssh-client qemu-system-x86 qemu-utils seabios \
        xorriso xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh ssh.sh /tools/
RUN chmod +x /tools/start.sh /tools/ssh.sh
ENTRYPOINT ["/tools/start.sh"]
