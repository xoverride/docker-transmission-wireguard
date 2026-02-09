# Helper image to install Transmission UIs
FROM alpine:latest AS transmissionui

RUN apk --no-cache add curl jq \
    && mkdir -p /opt/transmission-ui \
    && echo "Install Shift" \
    && wget -qO- https://github.com/killemov/Shift/archive/63c31becac6663c232c384f860438ed0395778fd.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/Shift-63c31becac6663c232c384f860438ed0395778fd /opt/transmission-ui/shift \
    && echo "Install Flood for Transmission" \
    && wget -qO- https://github.com/johman10/flood-for-transmission/releases/download/v1.0.1/flood-for-transmission.tar.gz | tar xz -C /opt/transmission-ui \
    && echo "Install Combustion" \
    && wget -qO- https://github.com/Secretmapper/combustion/archive/v0.6.4.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/combustion-0.6.4 /opt/transmission-ui/combustion-release \
    && echo "Install kettu" \
    && wget -qO- https://github.com/endor/kettu/archive/4ef4285c9e23662b4a5d7209af8164fe4e2c94da.tar.gz | tar xz -C /opt/transmission-ui \
    && mv /opt/transmission-ui/kettu-4ef4285c9e23662b4a5d7209af8164fe4e2c94da /opt/transmission-ui/kettu \
    && echo "Install Transmissionic" \
    && wget -qO- https://github.com/6c65726f79/Transmissionic/releases/download/v1.8.0/Transmissionic-webui-v1.8.0.zip | unzip -q - \
    && mv web /opt/transmission-ui/transmissionic

# Main image
FROM ubuntu:24.04

VOLUME /data
VOLUME /config

COPY --from=transmissionui /opt/transmission-ui /opt/transmission-ui

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    dumb-init transmission-daemon \
    tzdata dnsutils iputils-ping ufw iproute2 \
    openssh-client git jq curl wget unrar unzip bc \
    # New for this image
    wireguard nginx \
    # End new for this image
    && rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/* \
    && useradd -u 911 -U -d /config -s /bin/false abc \
    && usermod -G users abc


COPY start.sh /opt/wireguard/start.sh
COPY nginx_server.conf /opt/nginx/server.conf
COPY transmission-default-settings.json /opt/transmission/default-settings.json
COPY updateSettings.py /opt/transmission/
COPY userSetup.sh /opt/transmission/
RUN chmod +x /opt/wireguard/start.sh /opt/transmission/userSetup.sh

# Set some environment variables needed in various scripts
ENV TRANSMISSION_HOME=/config/transmission-home \
    TRANSMISSION_DOWNLOAD_DIR=/data/completed \
    TRANSMISSION_INCOMPLETE_DIR=/data/incomplete \
    TRANSMISSION_WATCH_DIR=/data/watch \
    GLOBAL_APPLY_PERMISSIONS=true \
    TRANSMISSION_UMASK=2

# Get base_revision passed as a build argument and set it as env var
ARG REVISION
ENV REVISION=${REVISION:-""}

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD curl --silent --fail http://localhost:9091/transmission/web/ || exit 1

CMD ["dumb-init", "-vv", "/opt/wireguard/start.sh"]