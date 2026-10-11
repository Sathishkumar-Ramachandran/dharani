#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "mesh/telemetry_codec.hpp"

namespace dharani::mesh {

// Wait-free single-producer / single-consumer ring buffer. N must be a power of two.
template <typename T, std::size_t N>
class SpscRing {
  static_assert((N & (N - 1)) == 0 && N >= 2, "capacity must be a power of two");

 public:
  bool push(const T& item) noexcept {
    const std::size_t h = head_.load(std::memory_order_relaxed);
    if (h - tail_.load(std::memory_order_acquire) == N) return false;  // full
    slots_[h & (N - 1)] = item;
    head_.store(h + 1, std::memory_order_release);
    return true;
  }
  std::optional<T> pop() noexcept {
    const std::size_t t = tail_.load(std::memory_order_relaxed);
    if (t == head_.load(std::memory_order_acquire)) return std::nullopt;
    T item = slots_[t & (N - 1)];
    tail_.store(t + 1, std::memory_order_release);
    return item;
  }
  std::size_t size() const noexcept { return head_.load() - tail_.load(); }

 private:
  std::array<T, N> slots_{};
  alignas(64) std::atomic<std::size_t> head_{0};
  alignas(64) std::atomic<std::size_t> tail_{0};
};

struct PeerEvent {
  SwarmMessage message;
  int rssi_dbm{0};          // 0 when the transport cannot report it
  std::int64_t received_ns{0};
};

struct PeerInfo {
  std::string vehicle_id;
  double lat{}, lon{};
  std::int64_t last_seen_ns{};
  bool tamper{};
};

// Tracks the vehicles heard recently (readers share the lock).
class SwarmPeerTable {
 public:
  void observe(const PeerEvent& ev);
  std::size_t active_count(std::int64_t now_ns, std::int64_t window_ns) const;
  std::vector<PeerInfo> snapshot() const;

 private:
  mutable std::shared_mutex mu_;
  std::unordered_map<std::string, PeerInfo> peers_;
};

}  // namespace dharani::mesh
