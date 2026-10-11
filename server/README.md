# Dharani server

Matching, live driver location and translated-conversation relay for the Dharani rider and driver apps.

```bash
cd server && dart pub get
DHARANI_SECRET='a-long-random-string' dart run bin/server.dart --port 8080 --journal rides.jsonl
dart test        # 17 integration tests over real sockets
```

* `POST /v1/register` `{name, role: rider|driver, lang}` -> `{userId, token}` (HMAC-signed, 30 days)
* `GET /v1/ws?token=...` WebSocket; first frame `{"t":"hello","protocol":1,"name","lang","vehicle"?}`
* `GET /healthz`, `GET /metrics`
* TLS: `--tls-cert fullchain.pem --tls-key privkey.pem` (then use `https://` in the apps), or terminate TLS at a proxy.

## Behaviour
Offers go to the nearest online drivers of the requested vehicle type within 6 km (3 at a time, 20 s each); the first
accept wins. A driver who cancels or disconnects (30 s grace) returns the ride to the pool. The OTP is only sent to
the rider. Chat frames are relayed only between the two parties of an active ride. Every frame is validated; frames
over 64 KB are refused; each connection is rate limited.

## Known limits (read before going live)
* State is in memory (one process). The journal is an audit trail, not a recovery log: active rides are lost on restart.
* Registration is open (rate limited). Plug your real identity (phone OTP / SSO) in front of `/v1/register`.
* Location proofs signed by the phones are not verified server-side yet.
* No payments or fare enforcement: the fare is what the rider's app computed.
