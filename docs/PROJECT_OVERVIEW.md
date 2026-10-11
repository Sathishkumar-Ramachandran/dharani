# Project Dharani — Overview

**Team:** Success

## 1. Project idea

Dharani is an **edge-native operating system for mobility and logistics**. Instead of a central
platform that owns the marketplace, the routing, the pricing and the data, every phone and vehicle
carries the intelligence itself:

- routing, fare calculation, map matching and traffic prediction run **on the device**;
- a driver and a rider (or a consignor and a transporter) are connected **directly**, so no
  middleman takes a commission;
- trust is established with **cryptography on the edge** (signed telemetry, hash-chained audit
  trail, escrow), not by trusting a platform's database;
- people who share no language still understand each other, because **speech-to-speech
  translation runs on the phone's NPU** (Qualcomm Snapdragon 8 Elite Gen 5 / QAIRT).

One codebase serves two markets: **B2C ride-hailing** (autos, cabs, bikes) and **B2B freight**
(Beckn-style RFQ → quote → contract → escrow → proof of delivery).

## 2. Problem statement

Indian urban mobility and freight run on platforms that were designed for the cloud, not for the
people and conditions on the ground. Five problems follow from that design.

1. **Commission and platform lock-in.** Aggregators keep 20–30% of each fare. Drivers and small
   fleet owners have no portable reputation or customer relationship, and prices are set by an
   opaque algorithm they cannot inspect.
2. **Dependence on connectivity and central servers.** Dispatch, routing and pricing all need a
   round trip to a data centre. In patchy coverage (highways, tunnels, towns outside the big
   metros) the service degrades or stops, and every ride adds cloud cost for the platform.
3. **Language barrier.** A rider who speaks Tamil, Hindi or French and a driver who speaks another
   language cannot agree on pickup point, fare or route. Existing translation apps are cloud
   based, slow, and unusable offline.
4. **Fraud and unverifiable data.** GPS spoofing, fake trips and inflated distances are common.
   A platform can only believe what the client app reports, and disputes are settled by whoever
   owns the logs.
5. **Freight trust gap.** Small transporters and consignors work on phone calls and paper.
   Quotes, payment release and proof of delivery have no shared, tamper-evident record, so
   payment disputes and delays are routine.

**The core question:** can the decision-making, trust and language layers of a mobility platform
move to the edge, so that the central service shrinks to a thin relay that anyone could run?

## 3. Solution

### 3.1 Architecture

```
 Rider phone (edge)            Relay server (thin)             Driver phone (edge)
 ┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
 │ C++ core engine  │        │ matching + offers│        │ C++ core engine  │
 │ routing · fares  │◄──WS──►│ OTP · call relay │◄──WS──►│ routing · fares  │
 │ map matching     │        │ audit journal    │        │ anti-spoof EKF   │
 │ NPU translation  │        │ LAN auto-discover│        │ NPU translation  │
 └──────────────────┘        └──────────────────┘        └──────────────────┘
        ▲        UDP mesh: hazards shared between nearby vehicles        ▲
```

### 3.2 What is built

| Layer | What it does |
|---|---|
| **Core engine** (C++20, no OpenSSL; Monocypher Ed25519 + own SHA-256) | A* routing with vehicle constraints (height/weight), HMM map matching, GCN traffic model, fare and toll estimation, offline OSM road graph. |
| **Anti-spoofing** | Extended Kalman Filter fuses GPS, odometer and gyro; impossible speed, mock-location provider and sensor inconsistencies are detected, and every attested position is **Ed25519-signed**. |
| **Beckn-B2B protocol layer** | State machine for freight: search → quote → contract → escrow → delivery proof, with a hash-chained audit log; verifiable by any party. |
| **FFI bridge** | Stable C ABI exposed to Dart via `dart:ffi` and JNI. |
| **Relay server** (Dart) | WebSocket hub: nearest-driver matching, offers with expiry, OTP start, ride lifecycle, voice-call relay, JSONL audit journal, token auth, rate limits, health and metrics. Discovered automatically on the local Wi-Fi (UDP). |
| **Mobile app** (Flutter) | Separate **Ride** (B2C) and **Freight** (B2B) tabs, real OpenStreetMap with GPS and simulation, driver and rider roles, in-app downloadable offline road region. |
| **Live voice call + translation** | Real-time two-way voice call between rider and driver. In interpreter mode each phone recognises its owner's speech on the **NPU (Whisper-Small via QAIRT / ONNX Runtime QNN)**, translates it on-device (ML Kit), sends only text over the socket, and the other phone speaks it. Languages: English, Hindi, Tamil, Telugu, Kannada, Marathi, Bengali, Gujarati, Urdu, French. |
| **Reliability** | Foreground service, wake and Wi-Fi locks, heads-up alert that wakes the phone on a new offer or call, reconnect with backoff, server-restart recovery. |

### 3.3 Why it is different

- **No commission model is needed.** Matching is a relay, not a marketplace; payment is paid
  directly to the driver.
- **Works with weak connectivity.** Routing, fares and map matching do not call a server.
- **Trust without a trusted operator.** Signed telemetry and a hash-chained audit trail can be
  verified by the counterparty, so disputes do not depend on one company's logs.
- **Privacy by design.** Audio never leaves the phone; only translated text is relayed.
- **Language-neutral.** Each user speaks and hears their own language.

### 3.4 Verification so far

- 6 native C++ test suites (ASan clean), 21 server tests, 51 Flutter tests.
- Run end to end on two real Snapdragon 8 Elite Gen 5 phones: matching, offer/accept, OTP,
  live call, and Hindi → French/Tamil interpreter translation on the NPU (~3 s per sentence).

### 3.5 Known limits (honest scope)

Calls and offers need the app running (no push notifications); the relay holds state in memory;
registration is open; the public OSM tile server is not for production; iOS has not been built;
the NPU model targets Snapdragon 8 Elite Gen 5; recognition accuracy depends on accent, noise and
speaking speed.

### 3.6 Roadmap

Push-wake (FCM) and persistent store for the relay, federated relays (any operator can run one),
payments via UPI, multi-device NPU models, on-device translation model to replace ML Kit,
iOS build, and a larger offline traffic model.
