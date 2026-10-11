#include "mesh/cv2x_sidelink.hpp"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>

namespace dharani::mesh {
namespace {
std::int64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}
}  // namespace

bool Cv2xSidelink::start(Handler handler, std::string own_vehicle_id, std::string* error) {
  if (running_.load()) return true;
  auto fail = [&](const char* what) {
    if (error) *error = std::string(what) + ": " + std::strerror(errno);
    if (fd_ >= 0) {
      ::close(fd_);
      fd_ = -1;
    }
    return false;
  };
  fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd_ < 0) return fail("socket");
  int on = 1;
  ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
#ifdef SO_REUSEPORT
  ::setsockopt(fd_, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
#endif
  if (::setsockopt(fd_, SOL_SOCKET, SO_BROADCAST, &on, sizeof on) < 0) return fail("SO_BROADCAST");
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port_);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (::bind(fd_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) < 0) return fail("bind");

  handler_ = std::move(handler);
  own_id_ = std::move(own_vehicle_id);
  running_.store(true);
  rx_ = std::thread([this] { receive_loop(); });
  dispatcher_ = std::thread([this] { dispatch_loop(); });
  return true;
}

void Cv2xSidelink::stop() {
  if (!running_.exchange(false)) return;
  if (rx_.joinable()) rx_.join();
  if (dispatcher_.joinable()) dispatcher_.join();
  if (fd_ >= 0) {
    ::close(fd_);
    fd_ = -1;
  }
}

bool Cv2xSidelink::publish(std::span<const std::uint8_t> datagram) {
  if (!running_.load() || datagram.empty() || datagram.size() > 1200) return false;
  sockaddr_in to{};
  to.sin_family = AF_INET;
  to.sin_port = htons(port_);
  to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
  bool ok = ::sendto(fd_, datagram.data(), datagram.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof to) ==
            static_cast<ssize_t>(datagram.size());
  // Also loop back on the local host so co-located instances (and tests) see the frame.
  to.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  ok = (::sendto(fd_, datagram.data(), datagram.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof to) ==
        static_cast<ssize_t>(datagram.size())) || ok;
  return ok;
}

void Cv2xSidelink::receive_loop() {
  std::array<std::uint8_t, 1500> buf;
  while (running_.load()) {
    pollfd p{fd_, POLLIN, 0};
    int r = ::poll(&p, 1, 200);
    if (r <= 0) continue;
    ssize_t n = ::recv(fd_, buf.data(), buf.size(), 0);
    if (n <= 0) continue;
    auto msg = decode_verified(std::span<const std::uint8_t>(buf.data(), static_cast<std::size_t>(n)));
    if (!msg) {
      dropped_invalid_.fetch_add(1);
      continue;
    }
    if (msg->vehicle() == own_id_) continue;
    PeerEvent ev{*msg, 0, now_ns()};
    peers_.observe(ev);
    if (!ring_.push(ev)) dropped_overflow_.fetch_add(1);
  }
}

void Cv2xSidelink::dispatch_loop() {
  while (running_.load()) {
    bool any = false;
    while (auto ev = ring_.pop()) {
      any = true;
      if (handler_) handler_(*ev);
    }
    if (!any) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
}

}  // namespace dharani::mesh
