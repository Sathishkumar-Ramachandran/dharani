#include "mesh/telemetry_codec.hpp"

#include <bit>
#include <cstring>

namespace dharani::mesh {
namespace {

constexpr std::size_t kBodySize = 103;

template <typename T>
void put(std::uint8_t* p, T v) {
  static_assert(std::is_trivially_copyable_v<T>);
  using U = std::conditional_t<sizeof(T) == 8, std::uint64_t, std::uint32_t>;
  U u = std::bit_cast<U>(v);
  for (std::size_t i = 0; i < sizeof(T); ++i) p[i] = static_cast<std::uint8_t>(u >> (8 * i));
}

template <typename T>
T get(const std::uint8_t* p) {
  using U = std::conditional_t<sizeof(T) == 8, std::uint64_t, std::uint32_t>;
  U u = 0;
  for (std::size_t i = 0; i < sizeof(T); ++i) u |= static_cast<U>(p[i]) << (8 * i);
  return std::bit_cast<T>(u);
}

void write_body(const SwarmMessage& m, std::uint8_t* b) {
  std::memcpy(b, "DHTM", 4);
  b[4] = 1;
  std::memcpy(b + 5, m.vehicle_id.data(), 36);
  put<std::uint64_t>(b + 41, m.timestamp_ns);
  put<double>(b + 49, m.lat);
  put<double>(b + 57, m.lon);
  put<float>(b + 65, m.alt);
  put<float>(b + 69, m.heading);
  put<float>(b + 73, m.speed);
  put<float>(b + 77, m.accuracy);
  put<std::uint32_t>(b + 81, m.engine_rpm);
  put<float>(b + 85, m.fuel_pct);
  put<std::uint32_t>(b + 89, m.fault_codes);
  put<float>(b + 93, m.battery_soc_pct);
  b[97] = static_cast<std::uint8_t>(m.hazard);
  put<float>(b + 98, m.severity);
  b[102] = m.tamper ? 1 : 0;
}

}  // namespace

std::string SwarmMessage::vehicle() const {
  std::size_t n = 0;
  while (n < vehicle_id.size() && vehicle_id[n] != '\0') ++n;
  return std::string(vehicle_id.data(), n);
}

void SwarmMessage::set_vehicle(std::string_view id) {
  vehicle_id.fill('\0');
  std::memcpy(vehicle_id.data(), id.data(), std::min(id.size(), vehicle_id.size()));
}

Datagram encode_signed(SwarmMessage msg, const crypto::AttestationEngine& engine) {
  Datagram out{};
  write_body(msg, out.data());
  auto digest = crypto::Sha256::hash(std::span<const std::uint8_t>(out.data(), kBodySize));
  // Sign through a proof object so the key never leaves the engine.
  crypto::Proof proof = engine.sign_digest(digest);
  msg.public_key = proof.public_key;
  msg.signature = proof.signature;
  std::memcpy(out.data() + kBodySize, msg.public_key.data(), 32);
  std::memcpy(out.data() + kBodySize + 32, msg.signature.data(), 64);
  return out;
}

std::optional<SwarmMessage> decode_verified(std::span<const std::uint8_t> bytes) {
  if (bytes.size() != kDatagramSize) return std::nullopt;
  const std::uint8_t* b = bytes.data();
  if (std::memcmp(b, "DHTM", 4) != 0 || b[4] != 1) return std::nullopt;
  if (b[97] > static_cast<std::uint8_t>(gnn::Hazard::StalledVehicle)) return std::nullopt;

  SwarmMessage m;
  std::memcpy(m.public_key.data(), b + kBodySize, 32);
  std::memcpy(m.signature.data(), b + kBodySize + 32, 64);
  auto digest = crypto::Sha256::hash(std::span<const std::uint8_t>(b, kBodySize));
  if (!crypto::verify_digest(m.public_key, digest, m.signature)) return std::nullopt;

  std::memcpy(m.vehicle_id.data(), b + 5, 36);
  m.timestamp_ns = get<std::uint64_t>(b + 41);
  m.lat = get<double>(b + 49);
  m.lon = get<double>(b + 57);
  m.alt = get<float>(b + 65);
  m.heading = get<float>(b + 69);
  m.speed = get<float>(b + 73);
  m.accuracy = get<float>(b + 77);
  m.engine_rpm = get<std::uint32_t>(b + 81);
  m.fuel_pct = get<float>(b + 85);
  m.fault_codes = get<std::uint32_t>(b + 89);
  m.battery_soc_pct = get<float>(b + 93);
  m.hazard = static_cast<gnn::Hazard>(b[97]);
  m.severity = get<float>(b + 98);
  m.tamper = b[102] != 0;
  if (!(m.lat >= -90 && m.lat <= 90 && m.lon >= -180 && m.lon <= 180)) return std::nullopt;
  if (!(m.severity >= 0 && m.severity <= 1)) return std::nullopt;
  return m;
}

}  // namespace dharani::mesh
