# irl-srt-server — SRT Live Server built against BELABOX SRT library
# Fixes NAK storms: LOSSMAXTTL=200 + SRTO_SRTLAPATCHES (no periodic NAK reports)
#
# Stage 1: Build irlserver/srt (belabox branch)
# Stage 2: Build irlserver/irl-srt-server (links against libsrt)
# Runtime:  debian:bookworm-slim + srt_server binary

# --- Stage 1: Build BELABOX SRT library ---
FROM debian:bookworm-slim AS srt-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake libssl-dev pkg-config ca-certificates \
    tclsh && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 -b belabox https://github.com/irlserver/srt.git /src/srt

WORKDIR /src/srt
RUN mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=/usr/local \
          -DENABLE_APPS=OFF \
          -DENABLE_SHARED=ON \
          .. && \
    make -j$(nproc) && \
    make install

# --- Stage 2: Build irl-srt-server ---
FROM debian:bookworm-slim AS sls-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake libssl-dev pkg-config ca-certificates libbsd-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy libsrt from stage 1
COPY --from=srt-builder /usr/local/lib/ /usr/local/lib/
COPY --from=srt-builder /usr/local/include/srt/ /usr/local/include/srt/
COPY --from=srt-builder /usr/local/lib/pkgconfig/ /usr/local/lib/pkgconfig/
RUN ldconfig

RUN git clone --depth 1 https://github.com/irlserver/irl-srt-server.git /src/sls

WORKDIR /src/sls
RUN git submodule update --init

# Patch: add libbsd for strlcpy (not in glibc, used across many source files)
# 1. Add #include <bsd/string.h> to shared header
# 2. Prepend link_libraries(bsd) to CMakeLists.txt (must come before targets)
RUN sed -i '1i #include <bsd/string.h>' src/core/common.hpp && \
    sed -i '1i link_libraries(bsd)' CMakeLists.txt

# Patch: Handle MediaMTX stream ID format (publish:live/streamkey)
# SLS expects 3-part slash-delimited SID (domain/app/stream), but Moblin/MediaMTX
# sends mode:domain/stream (e.g. "publish:live/key"). This adds fallback parsing
# for 2-part SIDs: "publish:live/key" → h=live, sls_app=live, r=key
RUN PATCH_LINE=$(grep -n 'ret\["r"\] = items.at(2);' src/core/SLSSrt.cpp | head -1 | cut -d: -f1) && \
    INSERT_LINE=$((PATCH_LINE + 1)) && \
    head -n "$INSERT_LINE" src/core/SLSSrt.cpp > /tmp/patched.cpp && \
    echo '        else if (items.size() == 2)' >> /tmp/patched.cpp && \
    echo '        {' >> /tmp/patched.cpp && \
    echo '            size_t cp = items.at(0).find(":");' >> /tmp/patched.cpp && \
    echo '            if (cp != std::string::npos)' >> /tmp/patched.cpp && \
    echo '            {' >> /tmp/patched.cpp && \
    echo '                ret["h"] = items.at(0).substr(cp + 1);' >> /tmp/patched.cpp && \
    echo '                ret["sls_app"] = items.at(0).substr(cp + 1);' >> /tmp/patched.cpp && \
    echo '            }' >> /tmp/patched.cpp && \
    echo '            else' >> /tmp/patched.cpp && \
    echo '            {' >> /tmp/patched.cpp && \
    echo '                ret["h"] = items.at(0);' >> /tmp/patched.cpp && \
    echo '                ret["sls_app"] = items.at(0);' >> /tmp/patched.cpp && \
    echo '            }' >> /tmp/patched.cpp && \
    echo '            ret["r"] = items.at(1);' >> /tmp/patched.cpp && \
    echo '        }' >> /tmp/patched.cpp && \
    tail -n +"$((INSERT_LINE + 1))" src/core/SLSSrt.cpp >> /tmp/patched.cpp && \
    mv /tmp/patched.cpp src/core/SLSSrt.cpp

# Patch: Force SRTO_SRTLAPATCHES=true on ALL connections (not just srtla port)
# Without this, the regular publisher port has dynamic reorder tolerance that
# drops to 0 after ordered deliveries, causing NAK storms when reordering resumes.
# SRTLA patches fix tolerance at 200 and suppress periodic NAK reports.
RUN sed -i '/SRTO_SRTLAPATCHES/i\    srtlaPatchesValue = 1;' src/core/SLSSrt.cpp

RUN mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    make -j$(nproc)

# Verify binary exists
RUN test -f build/bin/srt_server

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libbsd0 ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# Copy libsrt shared libraries
COPY --from=srt-builder /usr/local/lib/libsrt* /usr/local/lib/
RUN ldconfig

# Copy srt_server binary
COPY --from=sls-builder /src/sls/build/bin/srt_server /usr/local/bin/srt_server

ENTRYPOINT ["srt_server"]
CMD ["-c", "/etc/sls/sls.conf"]
