# A real Xastir, on the rig's shared channel, as an APRS station.
#
# Why this exists: AXTerm's APRS behaviour was matched to Xastir by *reading*
# `src/db.c` and writing prose comments. That is unfalsifiable — nothing fails
# if the reading was wrong. This container makes the reference implementation
# an executable oracle: AXTerm asks it a question over a simulated radio
# channel and we assert on what actually comes back.
#
# Two things Xastir cannot do that shape the whole design:
#
#   1. It has NO network-KISS device type. `enum Device_Types` (src/interface.h)
#      offers serial KISS, kernel AX.25, or AGWPE — nothing that dials a TCP
#      KISS port. So socat bridges a pty to the hub and Xastir opens the pty as
#      DEVICE_SERIAL_KISS_TNC (type 10).
#   2. It is an X11/Motif application with no headless mode, so it runs under
#      Xvfb. Nothing ever looks at the frame buffer; we only care what it puts
#      on the air.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        xastir xvfb socat procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY xastir.cnf.in /etc/xastir.cnf.in
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV CALLSIGN=XASTIR-1 \
    HUB_HOST=kisshub \
    HUB_PORT=8010 \
    STATION_LAT=3936.700N \
    STATION_LONG=10443.900W \
    UNPROTO1=WIDE1-1,WIDE2-1 \
    POSIT_RATE=600 \
    DISABLE_POSIT_TX=0 \
    XASTIR_DEBUG=0

CMD ["/entrypoint.sh"]
