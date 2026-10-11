# Project Dharani

Edge-native freight integrity stack: C++20 native core + Beckn-B2B contract/escrow layer, exposed
through a C ABI to a Flutter app. Everything runs on the phone; no map or routing API is called.

```
core-native/          crypto (SHA-256, Ed25519, EKF anti-spoofing), road graph, spatial index,
                      HMM map matcher, A* router (Valhalla-shaped facade), GNN traffic model, mesh
beckn-protocol-layer/ RFQ/quote schemas, state machine, escrow, hash-chained audit log, ledger
ffi-bridge/           dharani_c_api.h (stable C ABI), engine, JNI + iOS shims
mobile-ui/            Flutter app (Android + iOS projects)
tools/                gen_demo_graph.py, osm_to_graph.py, dharani_peer_sim (second-vehicle simulator)
third_party/          Monocypher (Ed25519), vendored
```

## Run on a USB-connected Android phone

One-time: Developer options -> USB debugging on, accept the RSA prompt. Toolchain used here:
Flutter 3.47, Android SDK 36, NDK 28.2, CMake 3.31 (Android Studio's JDK).

```bash
export ANDROID_HOME=$HOME/Library/Android/sdk
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH=$HOME/development/flutter/bin:$ANDROID_HOME/platform-tools:$PATH
adb devices                      # phone must say "device"
cd mobile-ui && flutter run      # builds libdharani_ffi.so for arm64 and installs
```

In the app: pick a lane, press **Create contract & start trip**. "Simulated drive" works indoors;
"Live GPS" needs a fix and only has roads inside the bundled Bengaluru-Krishnagiri map.
Try the fraud drills (GPS jump, frozen wheel sensor, cold-chain temperature, uplink outage).

## App structure (v0.3)

Tabs: **Ride** (B2C), **Freight** (B2B), **Translate**, **Account**. Real OpenStreetMap tiles with the live GPS dot;
Account -> *Offline roads* downloads OSM roads around you and hot-loads them into the native router.
Every trip can run on **Simulation** (virtual vehicle on the real route) or **Live GPS**.

## Two-phone mode (rider + driver)
`server/` (Dart) matches riders with drivers and relays live location and the translated conversation;
see [docs/TWO_PHONE_SETUP.md](docs/TWO_PHONE_SETUP.md) and run `tools/two_phones.sh`.

## Tests

```bash
cmake -S . -B build && cmake --build build && ctest --test-dir build      # 6 native suites
cd mobile-ui && DHARANI_FFI_LIB=$PWD/../build/ffi-bridge/libdharani_ffi.dylib flutter test
```

Mesh test with one phone: on the same Wi-Fi run
`build/tools/dharani_peer_sim 47474 blackice 0.9 12.80 77.70 60` and watch the hazard appear.

## What is real vs. stand-in (read this)

| Area | Status |
|---|---|
| Ed25519 signing, SHA-256 payload, verification, EKF fusion, tamper rules | Real, tested |
| Beckn state machine, escrow, dispute rules, hash-chained audit log | Real, tested (in-process ledger, no network between BAP/BPP) |
| C ABI, Dart FFI, NativeFinalizer, async mesh callback | Real, tested on host and on a phone |
| Routing / map matching | Real A* + HMM over a **synthetic demo graph**, not Valhalla. Use `tools/osm_to_graph.py` for real roads (untested here) |
| Spatial index | Grid buckets, not SpatiaLite/R-tree. No PMTiles: the map draws the graph on a canvas |
| GNN | 2-layer GCN with hand-set INT8 weights, no training, no ExecuTorch |
| Wire format | Fixed binary layout (`mesh/telemetry_codec.hpp`), **not FlatBuffers**; `.fbs` documents the fields |
| Device key | Seed stored in app-private storage; **not** StrongBox/Keystore/Secure Enclave yet |
| Mesh | UDP broadcast on shared Wi-Fi/hotspot. No C-V2X PC5, BLE or Wi-Fi Aware |
| NTN satellite | Store-and-forward queue counter only; no satellite link |
| CAN/OBD-II, FASTag, e-Way bill | Odometer derived from GPS speed; toll events and bill number are simulated |
| Real map | OSM raster tiles over the internet (public tile server: fine for testing, NOT for production traffic; use your own tile provider). Roads for routing are downloaded once per region |
| B2C rides | Fares, routing, Beckn contract and signed proofs are real; the **driver is simulated** |
| Translate | Speech recognition on the **Snapdragon NPU** (Whisper-Small via ONNX Runtime QNN, verified on SM8850; see docs/QAIRT_SETUP.md); translation + voice via ML Kit / Android TTS |
| iOS | Project generated, bridge written, **never built** (needs Xcode) |
