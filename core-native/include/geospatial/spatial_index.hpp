#pragma once
// Grid-bucket spatial index over road edges and nodes (a flat, cache-friendly stand-in for an
// R-tree; reads are lock-shared so the matcher and router can query concurrently).
#include <cmath>
#include <optional>
#include <shared_mutex>
#include <unordered_map>
#include <vector>

#include "geospatial/road_graph.hpp"

namespace dharani::geo {

class SpatialIndex {
 public:
  explicit SpatialIndex(const RoadGraph& graph, double cell_deg = 0.004);

  // Edge indices whose bounding box (expanded by radius) touches the query point. Callers still
  // need an exact distance test (see project_onto_edge).
  std::vector<std::uint32_t> edges_near(LatLon p, double radius_m) const;
  std::optional<std::uint32_t> nearest_node(LatLon p, double max_radius_m) const;

 private:
  using Key = std::uint64_t;
  Key key(std::int64_t ix, std::int64_t iy) const {
    return (static_cast<std::uint64_t>(static_cast<std::uint32_t>(ix)) << 32) |
           static_cast<std::uint32_t>(iy);
  }
  std::int64_t cell(double deg) const { return static_cast<std::int64_t>(std::floor(deg / cell_deg_)); }

  const RoadGraph& graph_;
  double cell_deg_;
  mutable std::shared_mutex mu_;
  std::unordered_map<Key, std::vector<std::uint32_t>> edge_cells_;
  std::unordered_map<Key, std::vector<std::uint32_t>> node_cells_;
};

}  // namespace dharani::geo
