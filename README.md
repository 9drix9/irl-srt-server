# irl-srt-server

SRT Live Server built against the [BELABOX SRT library](https://github.com/irlserver/srt/tree/belabox) with patches that fix NAK storms and improve cellular streaming stability.

```
Phone (SRTLA) → srtla_rec → irl-srt-server (SRT) → MediaMTX / OBS / Player
```

## Why

Standard SRT has a dynamic reorder tolerance that drops to 0 after a sequence of ordered packets. When packets arrive out-of-order again (common on cellular), the receiver floods the sender with NAK (negative acknowledgment) packets — a "NAK storm" that collapses bitrate.

The BELABOX SRT library fixes this with `LOSSMAXTTL=200` (fixed reorder tolerance) and `SRTO_SRTLAPATCHES` (suppresses periodic NAK reports). This server forces those patches on all connections, not just SRTLA ports.

## Patches

| # | Patch | Problem |
|---|-------|---------|
| 1 | libbsd strlcpy | SLS uses `strlcpy` which isn't in glibc — links against libbsd |
| 2 | MediaMTX stream ID | SLS expects 3-part stream IDs (`domain/app/stream`) but MediaMTX/Moblin send 2-part (`publish:live/key`). Adds fallback parser. |
| 3 | Force SRTLA patches | Enables `SRTO_SRTLAPATCHES=true` on ALL connections (not just SRTLA port), fixing NAK storms for direct SRT publishers too |

## Quick Start

```bash
git clone https://github.com/9drix9/irl-srt-server.git
cd irl-srt-server
docker build -t irl-srt-server .
docker run -d --network host \
  -v $(pwd)/sls.conf:/etc/sls/sls.conf:ro \
  --name irl-srt-server \
  irl-srt-server
```

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 8890 | SRT | Publisher port (streamers send here) |
| 4000 | SRT | Player port (readers/pullers connect here) |
| 4001 | SRT | SRTLA publisher port |
| 8181 | HTTP | Status API |

## Configuration

Edit `sls.conf` to customize:

```
srt {
    worker_threads 2;
    worker_connections 300;
    http_port 8181;
    log_file /dev/stdout;
    log_level info;

    server {
        listen_player 4000;
        listen_publisher 8890;
        listen_publisher_srtla 4001;

        latency_min 200;
        latency_max 5000;
        domain_player play;
        domain_publisher live;
        default_sid live/live/default;
        backlog 100;
        idle_streams_timeout 30;

        app {
            app_player live;
            app_publisher live;
            allow publish all;
            allow play all;
        }
    }
}
```

## Stream IDs

**Publishing** (streamers send to port 8890):
```
srt://server:8890?streamid=live/live/mystreamkey
```

**Playing** (readers pull from port 4000):
```
srt://server:4000?streamid=play/live/mystreamkey
```

The MediaMTX stream ID patch also accepts:
```
srt://server:8890?streamid=publish:live/mystreamkey
```

## Usage with MediaMTX

Configure MediaMTX to pull from irl-srt-server:

```yaml
paths:
  "~^live/(.+)$":
    source: "srt://localhost:4000?streamid=play/live/$G1&mode=caller"
    sourceOnDemand: true
    sourceOnDemandCloseAfter: 30s
```

## Usage with srtla-relay

Pair with [srtla-relay](https://github.com/9drix9/srtla-relay) for a complete ingest pipeline:

```
Phone → srtla-relay (geographic edge) → irl-srt-server (ingest) → MediaMTX → OBS
```

## Build Details

The Docker image is a multi-stage build:
1. **Stage 1**: Builds the BELABOX SRT library (`irlserver/srt`, belabox branch)
2. **Stage 2**: Builds irl-srt-server (`irlserver/irl-srt-server`) linked against BELABOX libsrt, with patches applied
3. **Runtime**: Minimal Debian image with just the `srt_server` binary and libsrt

## License

MIT
