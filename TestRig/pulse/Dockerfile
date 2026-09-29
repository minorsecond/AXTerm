# The ether: one PulseAudio null sink that every modem plays into and listens
# to, reachable over TCP so each station can run its own Direwolf in its own
# container.
#
# The existing `rf` profile runs PulseAudio *inside* Direwolf, which gives one
# modem hearing its own transmissions — real AFSK, but a single radio. Moving
# the sink out here makes it a shared medium: N modems, each with its own DCD,
# TXDELAY and slot timing, all mixing into the same monitor. Two stations that
# key at once genuinely garble each other in the audio domain rather than in a
# collision model.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        pulseaudio pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 4713
CMD ["/entrypoint.sh"]
