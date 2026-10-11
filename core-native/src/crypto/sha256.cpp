#include "crypto/sha256.hpp"

#include <algorithm>
#include <cstring>
#include <string>

namespace dharani::crypto {
namespace {

constexpr std::array<std::uint32_t, 64> kK = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

constexpr std::uint32_t rotr(std::uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

}  // namespace

void Sha256::reset() {
  state_ = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  total_bytes_ = 0;
  buffered_ = 0;
}

void Sha256::compress(const std::uint8_t* p) {
  std::array<std::uint32_t, 64> w;
  for (int i = 0; i < 16; ++i) {
    w[i] = (std::uint32_t(p[4 * i]) << 24) | (std::uint32_t(p[4 * i + 1]) << 16) |
           (std::uint32_t(p[4 * i + 2]) << 8) | std::uint32_t(p[4 * i + 3]);
  }
  for (int i = 16; i < 64; ++i) {
    std::uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    std::uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  auto [a, b, c, d, e, f, g, h] = state_;
  for (int i = 0; i < 64; ++i) {
    std::uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    std::uint32_t ch = (e & f) ^ (~e & g);
    std::uint32_t t1 = h + S1 + ch + kK[i] + w[i];
    std::uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    std::uint32_t t2 = S0 + maj;
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  state_[0] += a; state_[1] += b; state_[2] += c; state_[3] += d;
  state_[4] += e; state_[5] += f; state_[6] += g; state_[7] += h;
}

Sha256& Sha256::update(std::span<const std::uint8_t> data) {
  total_bytes_ += data.size();
  const std::uint8_t* p = data.data();
  std::size_t n = data.size();
  if (buffered_ > 0) {
    std::size_t take = std::min(n, buffer_.size() - buffered_);
    std::memcpy(buffer_.data() + buffered_, p, take);
    buffered_ += take;
    p += take;
    n -= take;
    if (buffered_ == buffer_.size()) {
      compress(buffer_.data());
      buffered_ = 0;
    }
  }
  while (n >= 64) {
    compress(p);
    p += 64;
    n -= 64;
  }
  if (n > 0) {
    std::memcpy(buffer_.data(), p, n);
    buffered_ = n;
  }
  return *this;
}

Digest Sha256::finish() {
  std::uint64_t bits = total_bytes_ * 8;
  std::uint8_t pad[72] = {0x80};
  std::size_t pad_len = (buffered_ < 56) ? (56 - buffered_) : (120 - buffered_);
  for (int i = 0; i < 8; ++i) pad[pad_len + i] = static_cast<std::uint8_t>(bits >> (56 - 8 * i));
  update(std::span<const std::uint8_t>(pad, pad_len + 8));
  Digest out;
  for (int i = 0; i < 8; ++i) {
    out[4 * i] = static_cast<std::uint8_t>(state_[i] >> 24);
    out[4 * i + 1] = static_cast<std::uint8_t>(state_[i] >> 16);
    out[4 * i + 2] = static_cast<std::uint8_t>(state_[i] >> 8);
    out[4 * i + 3] = static_cast<std::uint8_t>(state_[i]);
  }
  reset();
  return out;
}

std::string to_hex(std::span<const std::uint8_t> bytes) {
  static constexpr char digits[] = "0123456789abcdef";
  std::string s;
  s.reserve(bytes.size() * 2);
  for (auto b : bytes) {
    s += digits[b >> 4];
    s += digits[b & 15];
  }
  return s;
}

bool from_hex(std::string_view hex, std::span<std::uint8_t> out) {
  if (hex.size() != out.size() * 2) return false;
  auto nib = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  for (std::size_t i = 0; i < out.size(); ++i) {
    int hi = nib(hex[2 * i]), lo = nib(hex[2 * i + 1]);
    if (hi < 0 || lo < 0) return false;
    out[i] = static_cast<std::uint8_t>(hi * 16 + lo);
  }
  return true;
}

}  // namespace dharani::crypto
