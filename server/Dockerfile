FROM rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY migrations ./migrations
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home --home-dir /app ytwchat \
    && mkdir -p /app/storage/media \
    && chown -R ytwchat:ytwchat /app
WORKDIR /app
COPY --from=build /src/target/release/ytwchat-server /usr/local/bin/ytwchat-server
USER ytwchat
ENV BIND_ADDR=0.0.0.0:8001 MEDIA_DIR=/app/storage/media
EXPOSE 8001
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD curl -fsS http://127.0.0.1:8001/health || exit 1
CMD ["ytwchat-server"]
