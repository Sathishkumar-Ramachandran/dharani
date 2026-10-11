#include "crypto/attestation_engine.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>

#include "monocypher-ed25519.h"
#include "monocypher.h"

#if defined(_WIN32)
#error "Windows is not a supported target"
#else
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace dharani::crypto {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kGravity = 9.80665;
constexpr double kMaxSpeedMps = 140.0 / 3.6;  // 38.89 m/s
constexpr double kEarthRadius = 6371000.0;
constexpr double kUereMeters = 4.0;           // 1-sigma range error that DOP multiplies
constexpr double kMinPosSigma = 3.0;
constexpr double kGate3SigmaChi2Dof2 = 11.8290;  // chi-square(2), P = 0.9973 ("3 sigma")

double deg2rad(double d) { return d * kPi / 180.0; }

double haversine(double lat1, double lon1, double lat2, double lon2) {
  double dlat = deg2rad(lat2 - lat1), dlon = deg2rad(lon2 - lon1);
  double a = std::sin(dlat / 2) * std::sin(dlat / 2) +
             std::cos(deg2rad(lat1)) * std::cos(deg2rad(lat2)) * std::sin(dlon / 2) * std::sin(dlon / 2);
  return 2 * kEarthRadius * std::atan2(std::sqrt(a), std::sqrt(1 - a));
}

void put_u64(std::uint8_t* p, std::uint64_t v) {
  for (int i = 0; i < 8; ++i) p[i] = static_cast<std::uint8_t>(v >> (8 * i));
}

}  // namespace

std::string_view to_string(TamperReason r) {
  switch (r) {
    case TamperReason::None: return "none";
    case TamperReason::ImpossibleSpeed: return "impossible_speed";
    case TamperReason::DeadReckoningMismatch: return "dead_reckoning_mismatch";
    case TamperReason::OdometerMismatch: return "odometer_mismatch";
    case TamperReason::ImuInconsistent: return "imu_inconsistent";
    case TamperReason::ClockRegression: return "clock_regression";
    case TamperReason::MockLocation: return "mock_location";
  }
  return "unknown";
}

Digest payload_digest(std::string_view trip_id, double lat, double lon, std::int64_t timestamp_ns,
                      bool tamper) {
  std::uint8_t tail[25];
  put_u64(tail, std::bit_cast<std::uint64_t>(lat));
  put_u64(tail + 8, std::bit_cast<std::uint64_t>(lon));
  put_u64(tail + 16, static_cast<std::uint64_t>(timestamp_ns));
  tail[24] = tamper ? 1 : 0;
  Sha256 h;
  h.update(trip_id);
  h.update(std::span<const std::uint8_t>(tail, sizeof tail));
  return h.finish();
}

bool verify_digest(const PublicKey& pk, const Digest& digest, const Signature& sig) {
  return crypto_ed25519_check(sig.data(), pk.data(), digest.data(), digest.size()) == 0;
}

bool verify_proof(const PublicKey& pk, std::string_view trip_id, double lat, double lon,
                  std::int64_t timestamp_ns, bool tamper, const Signature& sig) {
  return verify_digest(pk, payload_digest(trip_id, lat, lon, timestamp_ns, tamper), sig);
}

// ---------------------------------------------------------------------------------------------
// Extended Kalman Filter. State x = [east, north, v_east, v_north] in a local tangent plane.
// ---------------------------------------------------------------------------------------------
struct AttestationEngine::Filter {
  using Vec4 = std::array<double, 4>;
  using Mat4 = std::array<double, 16>;

  bool initialized{false};
  double lat0{}, lon0{}, m_per_deg_lon{};
  Vec4 x{};
  Mat4 P{};
  GnssSample last_gnss{};
  std::int64_t last_ts{};
  std::uint64_t last_ticks{};
  bool have_odo{false};
  double last_gnss_speed{};
  double last_imu_dev{};     // |a| - g at previous step
  bool tamper{false};
  TamperReason reason{TamperReason::None};
  int outlier_streak{0};
  double last_nis{0}, last_innov{0};  // previous fix's normalised innovation (adaptive noise)

  void clear() {
    initialized = false;
    x = {};
    P = {};
    have_odo = false;
    last_gnss_speed = 0;
    last_imu_dev = 0;
    tamper = false;
    reason = TamperReason::None;
    outlier_streak = 0;
    last_nis = last_innov = 0;
  }

  void flag(TamperReason r) {
    if (!tamper) {
      tamper = true;
      reason = r;
    }
  }

  void to_local(double lat, double lon, double& e, double& n) const {
    e = (lon - lon0) * m_per_deg_lon;
    n = (lat - lat0) * 111320.0;
  }

  void init_at(const GnssSample& g, double pos_sigma) {
    lat0 = g.lat;
    lon0 = g.lon;
    m_per_deg_lon = 111320.0 * std::cos(deg2rad(g.lat));
    x = {0, 0, 0, 0};
    P = {};
    P[0] = P[5] = pos_sigma * pos_sigma;
    P[10] = P[15] = 25.0;  // unknown velocity
    last_gnss = g;
    last_ts = g.timestamp_ns;
    last_gnss_speed = 0;
    initialized = true;
  }

  // x = F x ; P = F P F' + Q  (constant velocity with acceleration noise sigma_a). `yaw` rotates
  // the velocity vector over the step (turning), so a vehicle that corners is not mistaken for a jump.
  void predict(double dt, double sigma_a, double yaw = 0.0) {
    const double vx0 = x[2], vy0 = x[3];
    if (yaw != 0.0) {
      const double c = std::cos(yaw), s = std::sin(yaw);
      x[2] = c * vx0 - s * vy0;
      x[3] = s * vx0 + c * vy0;
    }
    x[0] += 0.5 * (vx0 + x[2]) * dt;
    x[1] += 0.5 * (vy0 + x[3]) * dt;
    double q = sigma_a * sigma_a;
    double dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt2 * dt2;
    Mat4 F = {1, 0, dt, 0, 0, 1, 0, dt, 0, 0, 1, 0, 0, 0, 0, 1};
    Mat4 FP{}, FPFt{};
    for (int i = 0; i < 4; ++i)
      for (int j = 0; j < 4; ++j) {
        double s = 0;
        for (int k = 0; k < 4; ++k) s += F[i * 4 + k] * P[k * 4 + j];
        FP[i * 4 + j] = s;
      }
    for (int i = 0; i < 4; ++i)
      for (int j = 0; j < 4; ++j) {
        double s = 0;
        for (int k = 0; k < 4; ++k) s += FP[i * 4 + k] * F[j * 4 + k];
        FPFt[i * 4 + j] = s;
      }
    FPFt[0] += q * dt4 / 4;  FPFt[2] += q * dt3 / 2;
    FPFt[5] += q * dt4 / 4;  FPFt[7] += q * dt3 / 2;
    FPFt[8] += q * dt3 / 2;  FPFt[10] += q * dt2;
    FPFt[13] += q * dt3 / 2; FPFt[15] += q * dt2;
    P = FPFt;
  }

  // Joseph-free standard update for a measurement with row vector H (1x4) and scalar variance R.
  void update_scalar(const Vec4& H, double innovation, double R) {
    Vec4 PHt{};
    for (int i = 0; i < 4; ++i) {
      double s = 0;
      for (int k = 0; k < 4; ++k) s += P[i * 4 + k] * H[k];
      PHt[i] = s;
    }
    double S = R;
    for (int k = 0; k < 4; ++k) S += H[k] * PHt[k];
    if (S <= 1e-12) return;
    Vec4 K;
    for (int i = 0; i < 4; ++i) K[i] = PHt[i] / S;
    for (int i = 0; i < 4; ++i) x[i] += K[i] * innovation;
    Mat4 newP = P;
    for (int i = 0; i < 4; ++i)
      for (int j = 0; j < 4; ++j) newP[i * 4 + j] = P[i * 4 + j] - K[i] * PHt[j];
    P = newP;
  }

  // Normalised innovation squared of a 2D position measurement against the predicted state.
  double position_nis(double e, double n, double r2) const {
    double s00 = P[0] + r2, s01 = P[1], s10 = P[4], s11 = P[5] + r2;
    double det = s00 * s11 - s01 * s10;
    if (det <= 1e-12) return 0;
    double y0 = e - x[0], y1 = n - x[1];
    return (y0 * (s11 * y0 - s01 * y1) + y1 * (-s10 * y0 + s00 * y1)) / det;
  }
};

AttestationEngine::AttestationEngine() : filter_(new Filter) {
  std::array<std::uint8_t, 32> seed{};
  FILE* f = std::fopen("/dev/urandom", "rb");
  if (f == nullptr || std::fread(seed.data(), 1, seed.size(), f) != seed.size()) {
    if (f != nullptr) std::fclose(f);
    // /dev/urandom is always present on the supported targets; abort rather than sign with a weak key.
    std::abort();
  }
  std::fclose(f);
  crypto_ed25519_key_pair(secret_.data(), public_key_.data(), seed.data());
  crypto_wipe(seed.data(), seed.size());
}

AttestationEngine::AttestationEngine(const std::array<std::uint8_t, 32>& seed) : filter_(new Filter) {
  std::array<std::uint8_t, 32> copy = seed;  // key_pair wipes its seed argument
  crypto_ed25519_key_pair(secret_.data(), public_key_.data(), copy.data());
}

AttestationEngine::~AttestationEngine() {
  crypto_wipe(secret_.data(), secret_.size());
  delete filter_;
}

bool AttestationEngine::load_or_create_seed(const std::string& path, std::array<std::uint8_t, 32>& seed,
                                            std::string& error) {
  {
    std::ifstream in(path, std::ios::binary);
    if (in) {
      in.read(reinterpret_cast<char*>(seed.data()), seed.size());
      if (in.gcount() == static_cast<std::streamsize>(seed.size())) return true;
    }
  }
  FILE* r = std::fopen("/dev/urandom", "rb");
  if (r == nullptr || std::fread(seed.data(), 1, seed.size(), r) != seed.size()) {
    if (r != nullptr) std::fclose(r);
    error = "cannot read system entropy";
    return false;
  }
  std::fclose(r);
  FILE* w = std::fopen(path.c_str(), "wb");
  if (w == nullptr) {
    error = "cannot write device key at " + path;
    return false;
  }
  chmod(path.c_str(), S_IRUSR | S_IWUSR);
  bool ok = std::fwrite(seed.data(), 1, seed.size(), w) == seed.size();
  std::fclose(w);
  if (!ok) error = "short write while persisting device key";
  return ok;
}

void AttestationEngine::begin_trip(std::string_view trip_id) {
  std::lock_guard lock(mu_);
  trip_id_ = std::string(trip_id);
  filter_->clear();
}

void AttestationEngine::flag_external(TamperReason reason) noexcept {
  std::lock_guard lock(mu_);
  filter_->flag(reason);
}

bool AttestationEngine::ingest(const GnssSample& g, const ImuSample& imu, const OdometerSample& odo) noexcept {
  std::lock_guard lock(mu_);
  Filter& f = *filter_;
  const double pos_sigma = std::max(kMinPosSigma, g.dop * kUereMeters);
  const double r2 = pos_sigma * pos_sigma;

  if (!f.initialized) {
    f.init_at(g, pos_sigma);
    f.last_ticks = odo.ticks;
    f.have_odo = true;
    return !f.tamper;
  }

  const double dt = static_cast<double>(g.timestamp_ns - f.last_ts) * 1e-9;
  if (dt <= 0.0) {
    f.flag(TamperReason::ClockRegression);
    return false;
  }

  // IMU-derived quantities (orientation independent): |a| - g is the dynamic acceleration.
  const double a_norm = std::sqrt(imu.ax * imu.ax + imu.ay * imu.ay + imu.az * imu.az);
  const double a_dyn = std::fabs(a_norm - kGravity);
  const double yaw_rate = std::fabs(imu.gz);
  const double sigma_a = 1.0 + a_dyn + 0.5 * yaw_rate * std::max(f.last_gnss_speed, 1.0) * 0.1;

  // Raw GNSS jump versus physical capability of a road vehicle.
  const double jump_m = haversine(f.last_gnss.lat, f.last_gnss.lon, g.lat, g.lon);
  const double raw_speed = jump_m / dt;
  if (raw_speed > kMaxSpeedMps) f.flag(TamperReason::ImpossibleSpeed);

  // Wheel speed over this step (CAN-bus ticks).
  double odo_speed = -1.0;
  if (f.have_odo && odo.ticks >= f.last_ticks && odo.meters_per_tick > 0)
    odo_speed = static_cast<double>(odo.ticks - f.last_ticks) * odo.meters_per_tick / dt;

  // Pulling away from rest: the wheels report motion but the filter's velocity is still (nearly)
  // zero, so its direction is unknown. Make the velocity direction as uncertain as the wheel speed
  // allows; the next fixes then re-learn it instead of being judged against a bogus prediction.
  {
    const double fspeed = std::hypot(f.x[2], f.x[3]);
    if (odo_speed > 0.8 && fspeed < 0.7 * odo_speed) {
      const double var = odo_speed * odo_speed;
      f.P[10] = std::max(f.P[10], var);
      f.P[15] = std::max(f.P[15], var);
    }
  }

  // Dead-reckoning check: compare the fix with the IMU-driven EKF prediction. The phone's
  // orientation is unknown, so the gyroscope gives the turn rate but not its direction. The turn
  // direction is taken from the side the measured displacement bends toward relative to the
  // current velocity (cross product); the gyroscope supplies the magnitude.
  double e, n;
  f.to_local(g.lat, g.lon, e, n);
  const double omega = std::sqrt(imu.gx * imu.gx + imu.gy * imu.gy + imu.gz * imu.gz);
  double yaw = 0.0;
  if (omega >= 0.03) {
    double le, ln;  // the displacement between the two raw fixes is what the vehicle just did
    f.to_local(f.last_gnss.lat, f.last_gnss.lon, le, ln);
    const double cross = f.x[2] * (n - ln) - f.x[3] * (e - le);
    yaw = (cross >= 0 ? 1.0 : -1.0) * std::min(omega, 3.0) * dt;
    // The direction of the turn is only as good as the (noisy) displacement it is inferred from, so
    // while turning the heading of the velocity vector is made uncertain and re-learned quickly.
    const double v = std::hypot(f.x[2], f.x[3]);
    const double extra = 0.25 * v * v * yaw * yaw;
    f.P[10] += extra;
    f.P[15] += extra;
  }
  // Adaptive noise: after a poorly predicted fix the velocity (mostly its direction) is evidently
  // wrong, so let the next fixes correct it faster by making it as uncertain as the miss implies.
  if (f.last_nis > 2.5) {
    const double extra = 0.25 * f.last_innov * f.last_innov / (dt * dt);
    f.P[10] += extra;
    f.P[15] += extra;
  }
  f.predict(dt, sigma_a, yaw);
  const double nis = f.position_nis(e, n, r2);
  f.last_nis = nis;
  f.last_innov = std::hypot(e - f.x[0], n - f.x[1]);
  // A fix outside the 3-sigma gate is suspicious; it is a tamper event when it is grossly outside
  // (4x the gate) or the second one in a row. One marginal fix (GNSS multipath, a corner taken
  // between two samples) must not condemn an honest trip.
  const bool outlier = nis > kGate3SigmaChi2Dof2;
  const bool gross = nis > 4.0 * kGate3SigmaChi2Dof2;
  f.outlier_streak = outlier ? f.outlier_streak + 1 : 0;
  const bool reanchor = gross || f.outlier_streak >= 2;
  if (reanchor) f.flag(TamperReason::DeadReckoningMismatch);

  // IMU consistency: the change of GNSS speed has to be explainable by the measured acceleration.
  const double dv = std::fabs(raw_speed - f.last_gnss_speed);
  const double a_allow = std::max(a_dyn, f.last_imu_dev) + 1.0;
  const double dv_sigma = std::sqrt(2.0) * pos_sigma / dt + 0.5 * a_allow * dt;
  if (dv > a_allow * dt * 1.5 + 3.0 * dv_sigma + 2.0) f.flag(TamperReason::ImuInconsistent);

  // Odometer consistency (wheel speed from CAN-bus ticks).
  if (odo_speed >= 0) {
    const double r_odo = 0.5 * 0.5;
    const double sigma_v = std::sqrt(r_odo + 2.0 * r2 / (dt * dt));
    if (std::fabs(raw_speed - odo_speed) > 3.0 * sigma_v) f.flag(TamperReason::OdometerMismatch);
  } else if (f.have_odo && odo.ticks < f.last_ticks) {
    f.flag(TamperReason::OdometerMismatch);  // odometer rolled back
  }

  if (reanchor || raw_speed > kMaxSpeedMps) {
    // Re-anchor on the new fix so later samples are judged against it (the flag stays sticky).
    f.init_at(g, pos_sigma);
  } else {
    f.update_scalar({1, 0, 0, 0}, e - f.x[0], r2);
    f.update_scalar({0, 1, 0, 0}, n - f.x[1], r2);
    if (odo_speed >= 0) {
      const double v = std::hypot(f.x[2], f.x[3]);
      const double vv = std::max(v, 0.3);
      f.update_scalar({0, 0, f.x[2] / vv, f.x[3] / vv}, odo_speed - v, 0.25);
    }
  }

  f.last_gnss = g;
  f.last_ts = g.timestamp_ns;
  f.last_gnss_speed = raw_speed;
  f.last_imu_dev = a_dyn;
  f.last_ticks = odo.ticks;
  f.have_odo = true;
  return !f.tamper;
}

Proof AttestationEngine::prove(const GnssSample& at) const {
  std::lock_guard lock(mu_);
  Proof p;
  p.tamper_flag = filter_->tamper;
  p.reason = filter_->reason;
  p.public_key = public_key_;
  p.digest = payload_digest(trip_id_, at.lat, at.lon, at.timestamp_ns, p.tamper_flag);
  crypto_ed25519_sign(p.signature.data(), secret_.data(), p.digest.data(), p.digest.size());
  return p;
}

Proof AttestationEngine::sign_digest(const Digest& digest) const {
  Proof p;
  p.digest = digest;
  p.public_key = public_key_;
  crypto_ed25519_sign(p.signature.data(), secret_.data(), digest.data(), digest.size());
  return p;
}

Proof AttestationEngine::prove_current() const {
  GnssSample g;
  {
    std::lock_guard lock(mu_);
    g = filter_->last_gnss;
  }
  return prove(g);
}

bool AttestationEngine::verify(const Proof& proof) const {
  return verify_digest(public_key_, proof.digest, proof.signature);
}

bool AttestationEngine::tamper_flag() const noexcept {
  std::lock_guard lock(mu_);
  return filter_->tamper;
}

TamperReason AttestationEngine::tamper_reason() const noexcept {
  std::lock_guard lock(mu_);
  return filter_->reason;
}

double AttestationEngine::filtered_speed_mps() const noexcept {
  std::lock_guard lock(mu_);
  return std::hypot(filter_->x[2], filter_->x[3]);
}

std::string AttestationEngine::trip_id() const {
  std::lock_guard lock(mu_);
  return trip_id_;
}

}  // namespace dharani::crypto
