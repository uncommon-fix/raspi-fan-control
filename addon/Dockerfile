ARG BUILD_FROM
FROM $BUILD_FROM

# Install dependencies
RUN apk add --no-cache \
    bash \
    coreutils \
    findutils \
    jq \
    procps

# Copy rootfs
COPY rootfs /

# Copy scripts
COPY run.sh /
COPY health-check.sh /usr/local/bin/

# Set permissions
RUN chmod +x \
    /run.sh \
    /usr/local/bin/fan-control.sh \
    /usr/local/bin/fan-control-lib.sh \
    /usr/local/bin/health-check.sh

# Labels
LABEL \
    io.hass.name="Raspberry Pi 5 Fan Control" \
    io.hass.description="Temperature-based fan control with hysteresis" \
    io.hass.arch="aarch64" \
    io.hass.type="addon" \
    io.hass.version="1.0.0" \
    maintainer="uncommon-fix <https://github.com/uncommon-fix>"

CMD ["/run.sh"]
