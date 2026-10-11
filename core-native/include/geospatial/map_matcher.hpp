#pragma once
// Hidden Markov Model map matcher (Newson & Krumm): emission = Gaussian of GPS-to-road distance,
// transition = exponential of |great-circle distance - route distance|. Decoded with Viterbi.
#include <vector>

#include "geospatial/spatial_index.hpp"

namespace dharani::geo {

struct RawCoordinate {
  double lat{}, lon{}, accuracy_m{10};
};

struct MatchedPoint {
  std::int32_t edge_index{-1};  // -1 when no road within range
  LatLon snapped;
  double confidence{0};         // 0..1
};

struct MatcherConfig {
  double sigma_z_m = 8.0;       // GPS noise standard deviation
  double beta_m = 20.0;         // transition tolerance
  double search_radius_m = 60.0;
  double max_route_detour_m = 1500.0;
  std::size_t max_candidates = 6;
};

class MapMatcher {
 public:
  MapMatcher(const RoadGraph& graph, const SpatialIndex& index, MatcherConfig cfg = {})
      : graph_(graph), index_(index), cfg_(cfg) {}

  std::vector<MatchedPoint> match(const std::vector<RawCoordinate>& trace) const;

 private:
  struct Candidate {
    std::uint32_t edge;
    Projection proj;
  };
  double route_distance(const Candidate& from, const Candidate& to) const;

  const RoadGraph& graph_;
  const SpatialIndex& index_;
  MatcherConfig cfg_;
};

}  // namespace dharani::geo
