#include <atomic>
#include <chrono>
#include <thread>

#include "check.hpp"
#include "mesh/cv2x_sidelink.hpp"

using namespace dharani;

int main() {
  crypto::AttestationEngine alice, mallory;
  mesh::SwarmMessage m;
  m.set_vehicle("11111111-2222-3333-4444-555555555555");
  m.timestamp_ns = 123456789;
  m.lat = 12.5;
  m.lon = 77.5;
  m.alt = 900;
  m.heading = 90;
  m.speed = 17.5f;
  m.accuracy = 4;
  m.engine_rpm = 1800;
  m.fuel_pct = 63.5f;
  m.fault_codes = 2;
  m.battery_soc_pct = 88;
  m.hazard = gnn::Hazard::BlackIce;
  m.severity = 0.75f;
  m.tamper = true;

  auto bytes = mesh::encode_signed(m, alice);
  CHECK_EQ(bytes.size(), mesh::kDatagramSize);
  auto d = mesh::decode_verified(bytes);
  CHECK(d.has_value());
  if (d) {
    CHECK_EQ(d->vehicle(), "11111111-2222-3333-4444-555555555555");
    CHECK_EQ(d->timestamp_ns, 123456789u);
    CHECK_NEAR(d->lat, 12.5, 1e-12);
    CHECK_NEAR(d->speed, 17.5f, 1e-6);
    CHECK_EQ(d->engine_rpm, 1800u);
    CHECK(d->hazard == gnn::Hazard::BlackIce);
    CHECK_NEAR(d->severity, 0.75f, 1e-6);
    CHECK(d->tamper);
    CHECK(d->public_key == alice.public_key());
  }

  // Any flipped bit in the body, the key or the signature is rejected.
  for (std::size_t i : {std::size_t{6}, std::size_t{50}, std::size_t{97}, std::size_t{102}, std::size_t{110},
                        std::size_t{150}, std::size_t{198}}) {
    auto bad = bytes;
    bad[i] ^= 0x01;
    CHECK(!mesh::decode_verified(bad).has_value());
  }
  CHECK(!mesh::decode_verified(std::span<const std::uint8_t>(bytes.data(), 100)).has_value());

  // Ring buffer.
  mesh::SpscRing<int, 4> ring;
  CHECK(ring.push(1) && ring.push(2) && ring.push(3) && ring.push(4));
  CHECK(!ring.push(5));
  CHECK_EQ(*ring.pop(), 1);
  CHECK(ring.push(5));
  CHECK_EQ(*ring.pop(), 2);
  CHECK_EQ(ring.size(), 3u);

  // Loopback sidelink between two instances (skipped silently when the sandbox forbids sockets).
  mesh::Cv2xSidelink rx(47999), tx(47999);
  std::atomic<int> got{0};
  std::atomic<int> hazards{0};
  std::string err;
  bool up = rx.start([&](const mesh::PeerEvent& ev) {
    ++got;
    if (ev.message.hazard == gnn::Hazard::BlackIce) ++hazards;
  }, "receiver-vehicle", &err);
  bool up2 = tx.start([](const mesh::PeerEvent&) {}, "11111111-2222-3333-4444-555555555555", &err);
  if (up && up2) {
    auto good = mesh::encode_signed(m, alice);
    auto forged = good;
    forged[60] ^= 0x10;
    for (int i = 0; i < 20 && got.load() == 0; ++i) {
      tx.publish(forged);
      tx.publish(good);
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(got.load() >= 1);
    CHECK(hazards.load() >= 1);
    CHECK(rx.dropped_invalid() >= 1);
    CHECK(rx.peers().snapshot().size() == 1);
    CHECK(!tx.publish(std::span<const std::uint8_t>()));
  } else {
    std::fprintf(stderr, "note: sidelink loopback skipped (%s)\n", err.c_str());
  }
  rx.stop();
  tx.stop();
  TEST_MAIN_END();
}
