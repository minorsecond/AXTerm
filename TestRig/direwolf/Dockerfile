# Direwolf with a PulseAudio null-sink loopback: TX audio goes into the
# sink, RX audio comes from the sink's monitor — so the one modem hears
# its own channel, and every KISS client's frame is genuinely
# AFSK-modulated, demodulated, and delivered to all clients. Real DCD,
# real TXDELAY, real collisions.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        direwolf pulseaudio libasound2-plugins alsa-utils \
    && rm -rf /var/lib/apt/lists/*
COPY direwolf.conf /etc/direwolf.conf
COPY asound.conf /etc/asound.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8001
CMD ["/entrypoint.sh"]
