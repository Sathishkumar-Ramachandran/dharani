#include "mesh/swarm_peer.hpp"

#include <mutex>

namespace dharani::mesh {

void SwarmPeerTable::observe(const PeerEvent& ev) {
  std::unique_lock lock(mu_);
  PeerInfo& p = peers_[ev.message.vehicle()];
  p.vehicle_id = ev.message.vehicle();
  p.lat = ev.message.lat;
  p.lon = ev.message.lon;
  p.tamper = ev.message.tamper;
  p.last_seen_ns = ev.received_ns;
}

std::size_t SwarmPeerTable::active_count(std::int64_t now_ns, std::int64_t window_ns) const {
  std::shared_lock lock(mu_);
  std::size_t n = 0;
  for (const auto& kv : peers_)
    if (now_ns - kv.second.last_seen_ns <= window_ns) ++n;
  return n;
}

std::vector<PeerInfo> SwarmPeerTable::snapshot() const {
  std::shared_lock lock(mu_);
  std::vector<PeerInfo> out;
  out.reserve(peers_.size());
  for (const auto& kv : peers_) out.push_back(kv.second);
  return out;
}

}  // namespace dharani::mesh
