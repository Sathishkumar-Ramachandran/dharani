#pragma once
// Fixed-layout little-endian swarm datagram (199 bytes). It carries exactly the fields of
// proto/telemetry_swarm.fbs; the layout is flat so decoding is zero-copy and allocation free.
//
//   0  magic "DHTM"   4  version   5  vehicle_id[36]   41 timestamp_ns(u64)  49 lat(f64)  57 lon(f64)
//   65 alt(f32) 69 heading(f32) 73 speed(f32) 77 accuracy(f32)
//   81 engine_rpm(u32) 85 fuel_pct(f32) 89 fault_codes(u32) 93 battery_soc_pct(f32)
//   97 hazard(u8)  98 severity(f32)  102 tamper(u8)
//   103 public_key[32]  135 signature[64]   (Ed25519 over SHA-256 of bytes 0..102)
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

#include "crypto/attestation_engine.hpp"
#include "gnn/traffic_predictor.hpp"

namespace dharani::mesh {

constexpr std::size_t kDatagramSize = 199;

struct SwarmMessage {
  std::array<char, 36> vehicle_id{};  // UUID text, zero padded
  std::uint64_t timestamp_ns{};
  double lat{}, lon{};
  float alt{}, heading{}, speed{}, accuracy{};
  std::uint32_t engine_rpm{};
  float fuel_pct{};
  std::uint32_t fault_codes{};
  float battery_soc_pct{};
  gnn::Hazard hazard{gnn::Hazard::None};
  float severity{};
  bool tamper{};
  crypto::PublicKey public_key{};
  crypto::Signature signature{};

  std::string vehicle() const;
  void set_vehicle(std::string_view id);
};

using Datagram = std::array<std::uint8_t, kDatagramSize>;

// Fills public_key and signature using `engine`, returns the wire bytes.
Datagram encode_signed(SwarmMessage msg, const crypto::AttestationEngine& engine);

// Returns the message only when the framing is valid AND the Ed25519 signature verifies.
std::optional<SwarmMessage> decode_verified(std::span<const std::uint8_t> bytes);

}  // namespace dharani::mesh
