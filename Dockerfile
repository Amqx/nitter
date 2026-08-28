FROM nimlang/nim:2.2.6-alpine-regular as nim
LABEL maintainer="setenforce@protonmail.com"

RUN apk --no-cache add libsass-dev pcre

WORKDIR /src/nitter

COPY nitter.nimble .
RUN nimble install -y --depsOnly

COPY . .
RUN nimble build -d:danger -d:lto -d:strip --mm:refc \
    && nimble scss \
    && nimble md

FROM alpine:latest
WORKDIR /src/
# stunnel bridges nitter's plaintext redis client to TLS-only managed Redis
RUN apk --no-cache add pcre ca-certificates openssl stunnel netcat-openbsd
COPY --from=nim /src/nitter/nitter ./
COPY --from=nim /src/nitter/nitter.example.conf ./nitter.conf
COPY --from=nim /src/nitter/public ./public
COPY docker-entrypoint.sh ./
# Heroku runs the container as an arbitrary non-root UID, not the USER below.
RUN chmod 755 ./docker-entrypoint.sh
EXPOSE 8080
RUN adduser -h /src/ -D -s /bin/sh nitter
USER nitter
CMD ["./docker-entrypoint.sh", "./nitter"]
