# Production image (untested here: no Docker on the dev machine). AOT-compiled server on a minimal base.
FROM dart:stable AS build
WORKDIR /app
COPY packages/dharani_protocol packages/dharani_protocol
COPY server server
WORKDIR /app/server
RUN dart pub get && dart compile exe bin/server.dart -o /app/dharani-server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/dharani-server /app/bin/server
EXPOSE 8080
# Set DHARANI_SECRET (>= 16 chars) at run time; mount /data for the journal.
ENTRYPOINT ["/app/bin/server", "--port", "8080", "--journal", "/data/rides.jsonl"]
