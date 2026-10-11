#pragma once
// Allocation-free SHA-256 (FIPS 180-4).
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace dharani::crypto {

using Digest = std::array<std::uint8_t, 32>;

class Sha256 {
 public:
  Sha256() { reset(); }
  void reset();
  Sha256& update(std::span<const std::uint8_t> data);
  Sha256& update(std::string_view text) {
    return update(std::span(reinterpret_cast<const std::uint8_t*>(text.data()), text.size()));
  }
  Digest finish();

  static Digest hash(std::span<const std::uint8_t> data) {
    Sha256 h;
    h.update(data);
    return h.finish();
  }
  static Digest hash(std::string_view text) {
    Sha256 h;
    h.update(text);
    return h.finish();
  }

 private:
  void compress(const std::uint8_t* block);
  std::array<std::uint32_t, 8> state_{};
  std::array<std::uint8_t, 64> buffer_{};
  std::uint64_t total_bytes_{0};
  std::size_t buffered_{0};
};

std::string to_hex(std::span<const std::uint8_t> bytes);
bool from_hex(std::string_view hex, std::span<std::uint8_t> out);

}  // namespace dharani::crypto
