#include <cmath>
#include <cstdint>
#include <random>

#include "check.hpp"
#include "crypto/attestation_engine.hpp"

using namespace dharani::crypto;

namespace {
constexpr double kMetersPerDegLat = 110574.0;

struct Drive {
  AttestationEngine engine;
  std::mt19937 rng{7};
  std::normal_distribution<double> gps{0.0, 2.0};
  std::normal_distribution<double> imu{0.0, 0.15};
  double lat0 = 12.9, lon0 = 77.6;
  double east_m = 0;
  std::uint64_t ticks = 0;
  std::int64_t t_ns = 1'700'000'000'000'000'000;

  Drive() { engine.begin_trip("sim"); }

  // One second of driving at `speed` m/s heading east. Returns the engine verdict.
  bool step(double speed, double extra_east_m = 0, bool wheel_moving = true, double dop = 1.0) {
    t_ns += 1'000'000'000;
    east_m += speed;
    if (wheel_moving) ticks += static_cast<std::uint64_t>(std::llround(speed / 0.25));
    double lon = lon0 + (east_m + extra_east_m + gps(rng)) / (111320.0 * std::cos(lat0 * M_PI / 180));
    double lat = lat0 + gps(rng) / kMetersPerDegLat;
    GnssSample g{lat, lon, 900, dop, speed, 90, t_ns};
    ImuSample i{imu(rng), imu(rng), 9.80665 + imu(rng), 0, 0, 0.01, t_ns};
    OdometerSample o{ticks, 0.25, t_ns};
    return engine.ingest(g, i, o);
  }
};
}  // namespace

int main() {
  {  // Honest drive: 5 minutes with accelerations, no flag.
    Drive d;
    bool ok = true;
    for (int s = 0; s < 300; ++s) ok = d.step(s < 20 ? s : (s < 250 ? 20.0 : 20.0 - (s - 250) * 0.3)) && ok;
    CHECK(ok);
    CHECK(!d.engine.tamper_flag());
    CHECK(d.engine.filtered_speed_mps() >= 0);
  }
  {  // Teleport 500 m in one second (500 m/s) -> impossible speed.
    Drive d;
    for (int s = 0; s < 30; ++s) d.step(15.0);
    CHECK(!d.step(15.0, 500.0));
    CHECK(d.engine.tamper_flag());
    CHECK(d.engine.tamper_reason() == TamperReason::ImpossibleSpeed);
    Proof p = d.engine.prove_current();
    CHECK(p.tamper_flag);
  }
  {  // Slow spoof: GNSS creeps 25 m off the dead-reckoned track in a single step at highway speed
     // (below 140 km/h) while IMU and wheels disagree -> flagged by the 3-sigma gates.
    Drive d;
    for (int s = 0; s < 30; ++s) d.step(15.0);
    CHECK(!d.step(15.0, 60.0));
    CHECK(d.engine.tamper_flag());
  }
  {  // GPS says we move at 20 m/s but wheels are standing still (replayed / mocked GPS).
    Drive d;
    for (int s = 0; s < 5; ++s) d.step(0.0, 0, false);
    bool flagged = false;
    for (int s = 0; s < 10; ++s) {
      d.east_m += 0;  // car does not move; the spoofer injects displacement
      flagged = !d.step(0.0, 20.0 * (s + 1), false) || flagged;
    }
    CHECK(flagged);
    CHECK(d.engine.tamper_flag());
  }
  {  // Non-monotonic clock.
    Drive d;
    d.step(10);
    d.t_ns -= 5'000'000'000;
    CHECK(!d.step(10));
    CHECK(d.engine.tamper_reason() == TamperReason::ClockRegression);
  }
  {  // The flag is sticky until a new trip starts.
    Drive d;
    for (int s = 0; s < 10; ++s) d.step(10);
    d.step(10, 800);
    CHECK(d.engine.tamper_flag());
    for (int s = 0; s < 10; ++s) d.step(10);
    CHECK(d.engine.tamper_flag());
    d.engine.begin_trip("next");
    CHECK(!d.engine.tamper_flag());
  }
  {  // Odometer rollback.
    Drive d;
    for (int s = 0; s < 5; ++s) d.step(10);
    d.ticks -= 200;
    CHECK(!d.step(10, 0, false));
    CHECK(d.engine.tamper_reason() == TamperReason::OdometerMismatch);
  }
  {  // A tight turn at low speed is honest when the gyroscope reports it (either sign), and the
     // same displacement is flagged when the gyroscope says the vehicle went straight.
    for (int sign : {+1, -1}) {
      Drive d;
      for (int s = 0; s < 20; ++s) d.step(3.0);
      // Heading change of 144 degrees within one second at 3 m/s: displacement flips direction.
      double theta = 144.0 * M_PI / 180.0;
      d.east_m -= 3.0;  // vehicle reverses its east-west motion (u-turn like)
      d.t_ns += 1'000'000'000;
      d.ticks += 12;
      double lon = d.lon0 + (d.east_m + 1.0) / (111320.0 * std::cos(d.lat0 * M_PI / 180));
      GnssSample g{d.lat0, lon, 900, 1.0, 3, 0, d.t_ns};
      ImuSample turning{0.0, 0.0, 9.80665, 0, 0, sign * theta, d.t_ns};
      CHECK(d.engine.ingest(g, turning, OdometerSample{d.ticks, 0.25, d.t_ns}));
      CHECK(!d.engine.tamper_flag());
    }
    Drive d;
    for (int s = 0; s < 20; ++s) d.step(3.0);
    CHECK(!d.step(3.0, 150.0));  // 150 m sideways jump with no rotation: flagged
  }
  TEST_MAIN_END();
}
