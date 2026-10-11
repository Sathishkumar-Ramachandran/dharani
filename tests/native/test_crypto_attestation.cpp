#include <cmath>

#include "check.hpp"
#include "crypto/attestation_engine.hpp"
#include "crypto/sha256.hpp"

using namespace dharani::crypto;

int main() {
  // SHA-256 known answers.
  CHECK_EQ(to_hex(Sha256::hash("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK_EQ(to_hex(Sha256::hash("")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  std::string million(1000000, 'a');
  CHECK_EQ(to_hex(Sha256::hash(million)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");

  // Sign and verify a proof; any change to the payload invalidates it.
  AttestationEngine engine;
  engine.begin_trip("TRIP-42");
  GnssSample g{12.9716, 77.5946, 900, 1.0, 0, 0, 1'700'000'000'000'000'000};
  Proof p = engine.prove(g);
  CHECK(!p.tamper_flag);
  CHECK(engine.verify(p));
  CHECK(verify_proof(engine.public_key(), "TRIP-42", g.lat, g.lon, g.timestamp_ns, false, p.signature));
  CHECK(!verify_proof(engine.public_key(), "TRIP-43", g.lat, g.lon, g.timestamp_ns, false, p.signature));
  CHECK(!verify_proof(engine.public_key(), "TRIP-42", g.lat + 1e-6, g.lon, g.timestamp_ns, false, p.signature));
  CHECK(!verify_proof(engine.public_key(), "TRIP-42", g.lat, g.lon, g.timestamp_ns + 1, false, p.signature));
  CHECK(!verify_proof(engine.public_key(), "TRIP-42", g.lat, g.lon, g.timestamp_ns, true, p.signature));

  // A different device cannot forge it.
  AttestationEngine other;
  CHECK(!verify_proof(other.public_key(), "TRIP-42", g.lat, g.lon, g.timestamp_ns, false, p.signature));

  // Payload digest is deterministic.
  CHECK(payload_digest("T", 1.5, 2.5, 7, false) == payload_digest("T", 1.5, 2.5, 7, false));
  CHECK(payload_digest("T", 1.5, 2.5, 7, false) != payload_digest("T", 1.5, 2.5, 7, true));

  // The same seed restores the same identity.
  std::array<std::uint8_t, 32> seed{};
  for (int i = 0; i < 32; ++i) seed[i] = static_cast<std::uint8_t>(i * 7 + 1);
  AttestationEngine a(seed), b(seed);
  CHECK(a.public_key() == b.public_key());
  a.begin_trip("X");
  b.begin_trip("X");
  CHECK(a.prove(g).signature == b.prove(g).signature);  // Ed25519 is deterministic

  // The tamper flag is part of the signed payload.
  AttestationEngine t;
  t.begin_trip("T");
  ImuSample imu{0, 0, 9.81, 0, 0, 0, 0};
  OdometerSample odo{0, 0.5, 0};
  GnssSample f1{12.0, 77.0, 0, 1, 0, 0, 1'000'000'000};
  GnssSample f2{12.5, 77.5, 0, 1, 0, 0, 2'000'000'000};  // ~77 km in 1 s
  t.ingest(f1, imu, odo);
  CHECK(!t.ingest(f2, imu, odo));
  Proof flagged = t.prove(f2);
  CHECK(flagged.tamper_flag);
  CHECK(t.verify(flagged));
  CHECK(!verify_proof(t.public_key(), "T", f2.lat, f2.lon, f2.timestamp_ns, false, flagged.signature));

  TEST_MAIN_END();
}
