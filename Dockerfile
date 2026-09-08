# syntax=docker/dockerfile:1
# Build secrets are deliberately not accepted as ARGs. Runtime secrets are
# supplied only by Render after the immutable client/server artifacts are built.
FROM reg.mini.dev/busybox:latest-dev@sha256:6932aeda42156cf959bc30a80f828fad0105fa6bf2f1de96d92d0d6b12672f8c AS builder
USER root
RUN apk add --no-cache bash git curl unzip xz
# Render's rootless builder cannot map arbitrary UIDs in Flutter archives
# (e.g. Gradle wrapper UID 397546). Keep extracted files owned by the builder.
# This setting is build-only and does not propagate to the runtime stage.
ENV TAR_OPTIONS=--no-same-owner
RUN git clone --depth 1 --branch 3.47.2 https://github.com/flutter/flutter.git /opt/flutter \
    && test "$(git -C /opt/flutter rev-parse HEAD)" = d3b14c876900e553bc736ca19295fc09e3853e8e \
    && /opt/flutter/bin/flutter config --no-analytics --enable-web
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN /opt/flutter/bin/flutter pub get --enforce-lockfile
COPY lib/ lib/
COPY server/ server/
COPY web/ web/
COPY assets/ assets/
RUN /opt/flutter/bin/flutter build web --release --no-web-resources-cdn --dart-define=CURATOR_PREVIEW=true \
    && /opt/flutter/bin/dart compile exe server/curator_web_server.dart -o /app/curator-web

FROM reg.mini.dev/busybox:latest-dev@sha256:6932aeda42156cf959bc30a80f828fad0105fa6bf2f1de96d92d0d6b12672f8c AS native_deps
USER root
RUN apk add --no-cache tesseract=5.5.3-r0 tesseract-eng=5.5.3-r0 libavif-apps=1.4.2-r0 \
    && tesseract --list-langs \
    && avifdec --help | grep -- --size-limit
COPY tool/collect_native_runtime.sh /collect_native_runtime.sh
RUN /bin/sh /collect_native_runtime.sh

FROM reg.mini.dev/busybox:latest@sha256:314b6708489cad50f3af4a87d42fbb5fb250d10dcce7cfd468716bfd619c25cf
# Verified upstream contract: UID 1000, no working directory or entrypoint.
# Copy only native runtime dependencies, never apk, Flutter, Git or build tools.
COPY --from=native_deps /runtime/ /
WORKDIR /app
COPY --from=builder --chown=1000:1000 /app/curator-web ./curator-web
COPY --from=builder --chown=1000:1000 /app/build/web/ ./build/web/
COPY --from=builder --chown=1000:1000 /app/assets/ ./assets/
ENV PORT=10000 \
    CURATOR_ASSETS_DIR=/app/assets \
    CURATOR_WEB_DIR=/app/build/web \
    CURATOR_TESSERACT_BIN=/usr/bin/tesseract \
    CURATOR_AVIFDEC_BIN=/usr/bin/avifdec \
    CURATOR_OCR_LANGUAGE=eng \
    CURATOR_OCR_MAX_CONCURRENT_JOBS=1 \
    OMP_THREAD_LIMIT=1
EXPOSE 10000
CMD ["/app/curator-web"]
