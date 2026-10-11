#pragma once
// Two-layer graph convolutional network that turns time of day and peer-reported hazards into a
// per-edge speed factor in [0.25, 1]. Weights are INT8-quantised (per-tensor scale) and the
// forward pass is deterministic, allocation-bounded and runs on the CPU. The weights are
// hand-calibrated (not trained); the interface is what an ExecuTorch model would plug into.
#include <cstdint>
#include <span>
#include <vector>

#include "geospatial/road_graph.hpp"

namespace dharani::gnn {

enum class Hazard : std::uint8_t { None = 0, Pothole, Congestion, BlackIce, Detour, StalledVehicle };

struct HazardReport {
  geo::LatLon where;
  Hazard type{Hazard::None};
  float severity{0};          // 0..1
};

class TrafficPredictor {
 public:
  // Scalar helper kept for single-vehicle speed estimation from recent speed samples (kph).
  double predict_speed_kph(std::span<const float> recent_speeds_kph) const;

  // Speed multiplier for every graph edge (index-aligned with graph.edges()).
  std::vector<float> predict_edge_speed_factors(const geo::RoadGraph& graph, int hour_of_day,
                                                std::span<const HazardReport> hazards) const;
};

}  // namespace dharani::gnn
