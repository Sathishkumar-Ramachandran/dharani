#pragma once
// Offline routing facade with the shape of the Valhalla actor API (route + trace_attributes).
// The backend is a native A* router and HMM map matcher over the app's compact road graph, so
// the whole stack runs on-device without a tile server. A full Valhalla tile reader can be
// slotted in behind the same interface.
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "geospatial/map_matcher.hpp"
#include "geospatial/road_graph.hpp"
#include "geospatial/spatial_index.hpp"

namespace dharani::routing {

enum class CostingModel : int { Auto = 0, Truck = 1, TwoWheeler = 2 };

using RawCoordinate = geo::RawCoordinate;

struct VehicleProfile {
  double gross_weight_kg{0};
  double axle_load_kg{0};
  double height_m{0};
};

struct GuidanceStep {
  std::string instruction;
  double distance_m{};
  geo::LatLon at;
};

struct Route {
  std::vector<geo::LatLon> polyline;
  std::vector<GuidanceStep> steps;
  std::vector<std::uint32_t> edges;
  double distance_m{}, duration_s{}, carbon_grams{};
  int toll_plazas{};
};

class RoutingError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

class ValhallaEdgeService {
 public:
  // `tile_dir` must contain road_graph.json.
  explicit ValhallaEdgeService(const std::string& tile_dir);
  explicit ValhallaEdgeService(geo::RoadGraph graph);

  // `edge_speed_factors` (optional) is index-aligned with graph edges, e.g. from the GNN.
  Route CalculateRoute(double startLat, double startLon, double destLat, double destLon, CostingModel costing,
                       const VehicleProfile& vehicle = {},
                       const std::vector<float>* edge_speed_factors = nullptr) const;

  std::vector<geo::MatchedPoint> MapMatch(const std::vector<RawCoordinate>& trace) const;

  const geo::RoadGraph& graph() const { return graph_; }
  const geo::SpatialIndex& index() const { return *index_; }

 private:
  geo::RoadGraph graph_;
  std::unique_ptr<geo::SpatialIndex> index_;
  std::unique_ptr<geo::MapMatcher> matcher_;
};

}  // namespace dharani::routing
