#include "gnn/traffic_predictor.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace dharani::gnn {
namespace {

constexpr int kIn = 5;      // rush, congestion, black ice, pothole/stalled, degree
constexpr int kHidden = 6;
constexpr float kScale1 = 1.0f / 32.0f;  // INT8 dequantisation scales
constexpr float kScale2 = 1.0f / 32.0f;

// W1 [kIn x kHidden], INT8. Hidden unit h reads feature h (identity block) plus a small mixing term.
constexpr std::array<std::int8_t, kIn * kHidden> kW1 = {
    32, 0, 0, 0, 0, 4,   // rush
    0, 32, 0, 0, 0, 4,   // congestion
    0, 0, 32, 0, 0, 4,   // black ice
    0, 0, 0, 32, 0, 2,   // pothole / stalled
    0, 0, 0, 0, 8, 0,    // degree (junctions slow traffic a little)
};
constexpr std::array<float, kHidden> kB1 = {0, 0, 0, 0, 0, 0};
// W2 [kHidden x 1]: how much each hidden channel reduces speed.
constexpr std::array<std::int8_t, kHidden> kW2 = {14, 110, 96, 34, 6, 4};

float relu(float x) { return x > 0 ? x : 0; }

float rush_signal(int hour) {
  double h = hour;
  return static_cast<float>(0.8 * (std::exp(-(h - 9) * (h - 9) / 8.0) + std::exp(-(h - 18) * (h - 18) / 8.0)));
}

}  // namespace

double TrafficPredictor::predict_speed_kph(std::span<const float> x) const {
  if (x.empty()) return 0;
  // Exponentially weighted mean emphasising the most recent samples.
  double num = 0, den = 0, w = 1;
  for (std::size_t i = x.size(); i-- > 0;) {
    num += w * x[i];
    den += w;
    w *= 0.8;
  }
  return std::clamp(num / den, 0.0, 140.0);
}

std::vector<float> TrafficPredictor::predict_edge_speed_factors(const geo::RoadGraph& g, int hour,
                                                                std::span<const HazardReport> hazards) const {
  const std::size_t n = g.node_count();
  std::vector<std::array<float, kIn>> feat(n);
  const float rush = rush_signal(((hour % 24) + 24) % 24);
  for (std::size_t i = 0; i < n; ++i) {
    feat[i] = {rush, 0, 0, 0, std::min(4.0f, static_cast<float>(g.adjacent(static_cast<std::uint32_t>(i)).size())) / 4.0f};
  }
  for (const HazardReport& h : hazards) {
    if (h.type == Hazard::None || h.severity <= 0) continue;
    for (std::size_t i = 0; i < n; ++i) {
      double d = geo::haversine_m(h.where, g.nodes()[i]);
      if (d > 1500) continue;
      float influence = h.severity * static_cast<float>(std::exp(-(d * d) / (2.0 * 400.0 * 400.0)));
      switch (h.type) {
        case Hazard::Congestion: feat[i][1] += influence; break;
        case Hazard::BlackIce: feat[i][2] += influence; break;
        case Hazard::Pothole:
        case Hazard::StalledVehicle: feat[i][3] += influence; break;
        case Hazard::Detour: feat[i][1] += 0.5f * influence; break;
        case Hazard::None: break;
      }
    }
  }

  // Layer 1: H1 = ReLU(A_hat X W1 + b1), A_hat = D^-1 (A + I)
  std::vector<std::array<float, kHidden>> h1(n);
  for (std::size_t i = 0; i < n; ++i) {
    std::array<float, kIn> agg = feat[i];
    const auto& adj = g.adjacent(static_cast<std::uint32_t>(i));
    for (const auto& a : adj)
      for (int k = 0; k < kIn; ++k) agg[k] += feat[a.to][k];
    const float inv = 1.0f / static_cast<float>(adj.size() + 1);
    for (int j = 0; j < kHidden; ++j) {
      float s = kB1[j];
      for (int k = 0; k < kIn; ++k) s += agg[k] * inv * (kW1[k * kHidden + j] * kScale1);
      h1[i][j] = relu(s);
    }
  }
  // Layer 2: z = A_hat H1 W2, factor = 0.25 + 0.75 exp(-z)
  std::vector<float> node_factor(n);
  for (std::size_t i = 0; i < n; ++i) {
    std::array<float, kHidden> agg = h1[i];
    const auto& adj = g.adjacent(static_cast<std::uint32_t>(i));
    for (const auto& a : adj)
      for (int j = 0; j < kHidden; ++j) agg[j] += h1[a.to][j];
    const float inv = 1.0f / static_cast<float>(adj.size() + 1);
    float z = 0;
    for (int j = 0; j < kHidden; ++j) z += agg[j] * inv * (kW2[j] * kScale2);
    node_factor[i] = 0.25f + 0.75f * std::exp(-z);
  }

  std::vector<float> out(g.edge_count());
  for (std::size_t e = 0; e < out.size(); ++e) {
    const auto& edge = g.edges()[e];
    out[e] = 0.5f * (node_factor[edge.a] + node_factor[edge.b]);
  }
  return out;
}

}  // namespace dharani::gnn
