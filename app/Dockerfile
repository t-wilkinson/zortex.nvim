# app/Dockerfile: zortex serve (notes web app, calendar, notifications, pomodoro)
FROM golang:1.24-alpine AS build
WORKDIR /src
ARG VERSION=dev
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /zortex ./cmd/zortex

FROM alpine:3.20
LABEL org.opencontainers.image.source="https://github.com/t-wilkinson/zortex.nvim" \
      org.opencontainers.image.description="zortex serve: notes web app, calendar, ntfy notifications, pomodoro" \
      org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache ca-certificates tzdata && adduser -D -H -u 10001 zortex && mkdir -p /data && chown zortex /data
COPY --from=build /zortex /usr/local/bin/zortex
USER zortex
ENV ZORTEX_NOTES_DIR=/notes ZORTEX_DATA_DIR=/data ZORTEX_ADDR=0.0.0.0:8090
EXPOSE 8090
HEALTHCHECK --interval=1m --timeout=5s CMD wget -qO- http://127.0.0.1:8090/healthz >/dev/null || exit 1
ENTRYPOINT ["zortex", "serve"]
