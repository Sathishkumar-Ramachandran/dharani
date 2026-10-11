#pragma once
// Proof-of-Location / Proof-of-Custody engine.
//
// An Extended Kalman Filter fuses GNSS fixes, IMU specific force and odometer (wheel tick) speed.
// Any physically impossible motion, or a GNSS fix that disagrees with the filter's IMU-driven
// prediction by more than 3 sigma, sets a sticky TamperFlag. Every proof is
//   Payload = SHA256(TripID || Lat || Lon || Timestamp || TamperFlag)
// signed with the device's Ed25519 key.
#include <array>
#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>

#include "crypto/sha256.hpp"

namespace dharani::crypto {

struct GnssSample {
  double lat{}, lon{}, alt{};
  double dop{1.0};            // dilution of precision reported by the receiver
  double speed_mps{};         // receiver-reported ground speed (informational)
  double heading_deg{};
  std::int64_t timestamp_ns{};
};

struct ImuSample {
  double ax{}, ay{}, az{};    // m/s^2, specific force including gravity
  double gx{}, gy{}, gz{};    // rad/s
  std::int64_t timestamp_ns{};
};

struct OdometerSample {
  std::uint64_t ticks{};      // cumulative wheel ticks (CAN-bus)
  double meters_per_tick{};
  std::int64_t timestamp_ns{};
};

enum class TamperReason : std::uint8_t {
  None = 0,
  ImpossibleSpeed,       // GNSS jump implies > 140 km/h
  DeadReckoningMismatch, // GNSS vs. IMU-driven EKF prediction beyond 3 sigma
  OdometerMismatch,      // GNSS speed vs. wheel speed beyond 3 sigma
  ImuInconsistent,       // speed change not explainable by measured acceleration
  ClockRegression,       // non-monotonic timestamps
  MockLocation,          // the OS reports a mock/test location provider
};

std::string_view to_string(TamperReason r);

using PublicKey = std::array<std::uint8_t, 32>;
using Signature = std::array<std::uint8_t, 64>;

struct Proof {
  Digest digest{};
  Signature signature{};
  PublicKey public_key{};
  bool tamper_flag{};
  TamperReason reason{TamperReason::None};
};

// Canonical payload: trip id bytes, then lat, lon (IEEE-754 little endian), timestamp (int64 LE),
// tamper flag (1 byte).
Digest payload_digest(std::string_view trip_id, double lat, double lon, std::int64_t timestamp_ns,
                      bool tamper);

// Receiving edge nodes use this: recomputes the payload and checks the signature.
bool verify_proof(const PublicKey& public_key, std::string_view trip_id, double lat, double lon,
                  std::int64_t timestamp_ns, bool tamper, const Signature& signature);
bool verify_digest(const PublicKey& public_key, const Digest& digest, const Signature& signature);

class AttestationEngine {
 public:
  // Generates a fresh key pair.
  AttestationEngine();
  // Restores a key from a 32-byte seed.
  explicit AttestationEngine(const std::array<std::uint8_t, 32>& seed);
  ~AttestationEngine();
  AttestationEngine(const AttestationEngine&) = delete;
  AttestationEngine& operator=(const AttestationEngine&) = delete;

  // Loads the seed from `path`, or creates it (owner read/write only) when absent.
  static bool load_or_create_seed(const std::string& path, std::array<std::uint8_t, 32>& seed,
                                  std::string& error);

  // Starts a new trip: resets the filter and clears the tamper flag.
  void begin_trip(std::string_view trip_id);

  // Raises the sticky tamper flag from outside the filter (e.g. OS mock-location indicator).
  void flag_external(TamperReason reason) noexcept;

  // Feeds one synchronized sample set. Returns false when the sample set is tamper-flagged.
  // Performs no heap allocation.
  bool ingest(const GnssSample& gnss, const ImuSample& imu, const OdometerSample& odo) noexcept;

  Proof prove(const GnssSample& at) const;
  Proof sign_digest(const Digest& digest) const;  // signs an arbitrary digest with the device key
  Proof prove_current() const;  // proof for the last ingested fix
  bool verify(const Proof& proof) const;  // verify against this engine's own key
  PublicKey public_key() const noexcept { return public_key_; }
  bool tamper_flag() const noexcept;
  TamperReason tamper_reason() const noexcept;
  double filtered_speed_mps() const noexcept;
  std::string trip_id() const;

 private:
  struct Filter;
  void reset_filter_locked() noexcept;

  mutable std::mutex mu_;
  std::array<std::uint8_t, 64> secret_{};
  PublicKey public_key_{};
  std::string trip_id_;
  Filter* filter_;
};

}  // namespace dharani::crypto
