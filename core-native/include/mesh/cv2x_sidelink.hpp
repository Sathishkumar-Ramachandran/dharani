#pragma once
// Sidelink transport. Phones do not expose a C-V2X PC5 modem, so the portable transport is a UDP
// broadcast on the local Wi-Fi / hotspot segment (same role as Wi-Fi Aware / BLE mesh: direct
// vehicle-to-vehicle datagrams with no internet). A PC5 radio plugs in behind the same class.
#include <atomic>
#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <thread>

#include "mesh/swarm_peer.hpp"

namespace dharani::mesh {

class Cv2xSidelink {
 public:
  using Handler = std::function<void(const PeerEvent&)>;

  explicit Cv2xSidelink(std::uint16_t port = 47474) : port_(port) {}
  ~Cv2xSidelink() { stop(); }
  Cv2xSidelink(const Cv2xSidelink&) = delete;
  Cv2xSidelink& operator=(const Cv2xSidelink&) = delete;

  // Handler runs on a dispatcher thread, never on the receive thread. Datagrams from
  // `own_vehicle_id` are ignored. Only datagrams whose Ed25519 signature verifies reach it.
  bool start(Handler handler, std::string own_vehicle_id, std::string* error = nullptr);
  void stop();
  bool running() const { return running_.load(); }

  // Broadcast a datagram (<= 1200 bytes).
  bool publish(std::span<const std::uint8_t> datagram);

  const SwarmPeerTable& peers() const { return peers_; }
  std::uint64_t dropped_invalid() const { return dropped_invalid_.load(); }
  std::uint64_t dropped_overflow() const { return dropped_overflow_.load(); }

 private:
  void receive_loop();
  void dispatch_loop();

  std::uint16_t port_;
  int fd_{-1};
  std::atomic<bool> running_{false};
  std::thread rx_, dispatcher_;
  Handler handler_;
  std::string own_id_;
  SpscRing<PeerEvent, 128> ring_;
  SwarmPeerTable peers_;
  std::atomic<std::uint64_t> dropped_invalid_{0}, dropped_overflow_{0};
};

}  // namespace dharani::mesh
