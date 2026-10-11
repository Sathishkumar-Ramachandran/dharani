// Plays a second vehicle on the sidelink: broadcasts signed hazard / presence datagrams so a
// single phone can be tested end to end from a laptop on the same Wi-Fi.
//
//   dharani_peer_sim <port> <pothole|congestion|blackice|detour|stalled|none> <severity 0..1> <lat> <lon> <seconds>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "mesh/cv2x_sidelink.hpp"

using namespace dharani;

int main(int argc, char** argv) {
  if (argc < 7) {
    std::fprintf(stderr, "usage: %s <port> <hazard> <severity> <lat> <lon> <seconds>\n", argv[0]);
    return 2;
  }
  const auto port = static_cast<std::uint16_t>(std::atoi(argv[1]));
  const std::string kind = argv[2];
  gnn::Hazard hazard = gnn::Hazard::None;
  if (kind == "pothole") hazard = gnn::Hazard::Pothole;
  else if (kind == "congestion") hazard = gnn::Hazard::Congestion;
  else if (kind == "blackice") hazard = gnn::Hazard::BlackIce;
  else if (kind == "detour") hazard = gnn::Hazard::Detour;
  else if (kind == "stalled") hazard = gnn::Hazard::StalledVehicle;
  else if (kind != "none") {
    std::fprintf(stderr, "unknown hazard '%s'\n", kind.c_str());
    return 2;
  }
  const double severity = std::atof(argv[3]), lat = std::atof(argv[4]), lon = std::atof(argv[5]);
  const int seconds = std::atoi(argv[6]);

  crypto::AttestationEngine key;
  mesh::Cv2xSidelink link(port);
  std::string err;
  if (!link.start([](const mesh::PeerEvent&) {}, "peer-sim-0000", &err)) {
    std::fprintf(stderr, "cannot open sidelink: %s\n", err.c_str());
    return 1;
  }
  std::printf("broadcasting %s on udp/%u for %d s\n", kind.c_str(), port, seconds);
  for (int i = 0; i < seconds * 2; ++i) {
    mesh::SwarmMessage m;
    m.set_vehicle("peer-sim-0000");
    m.timestamp_ns = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
    m.lat = lat;
    m.lon = lon;
    m.speed = 12.0f;
    m.hazard = hazard;
    m.severity = static_cast<float>(severity);
    link.publish(mesh::encode_signed(m, key));
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  link.stop();
  return 0;
}
