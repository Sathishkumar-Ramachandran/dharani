#include "geospatial/spatial_index.hpp"

#include <algorithm>
#include <cmath>
#include <mutex>

namespace dharani::geo {

SpatialIndex::SpatialIndex(const RoadGraph& graph, double cell_deg) : graph_(graph), cell_deg_(cell_deg) {
  std::unique_lock lock(mu_);
  for (std::uint32_t i = 0; i < graph.edge_count(); ++i) {
    const Edge& e = graph.edges()[i];
    LatLon a = graph.nodes()[e.a], b = graph.nodes()[e.b];
    for (std::int64_t ix = cell(std::min(a.lon, b.lon)); ix <= cell(std::max(a.lon, b.lon)); ++ix)
      for (std::int64_t iy = cell(std::min(a.lat, b.lat)); iy <= cell(std::max(a.lat, b.lat)); ++iy)
        edge_cells_[key(ix, iy)].push_back(i);
  }
  for (std::uint32_t i = 0; i < graph.node_count(); ++i) {
    const LatLon& n = graph.nodes()[i];
    node_cells_[key(cell(n.lon), cell(n.lat))].push_back(i);
  }
}

std::vector<std::uint32_t> SpatialIndex::edges_near(LatLon p, double radius_m) const {
  std::shared_lock lock(mu_);
  const double dlat = radius_m / 110574.0;
  const double dlon = radius_m / (111320.0 * std::max(0.01, std::cos(p.lat * 3.14159265358979323846 / 180.0)));
  std::vector<std::uint32_t> out;
  for (std::int64_t ix = cell(p.lon - dlon); ix <= cell(p.lon + dlon); ++ix)
    for (std::int64_t iy = cell(p.lat - dlat); iy <= cell(p.lat + dlat); ++iy) {
      auto it = edge_cells_.find(key(ix, iy));
      if (it != edge_cells_.end()) out.insert(out.end(), it->second.begin(), it->second.end());
    }
  std::sort(out.begin(), out.end());
  out.erase(std::unique(out.begin(), out.end()), out.end());
  return out;
}

std::optional<std::uint32_t> SpatialIndex::nearest_node(LatLon p, double max_radius_m) const {
  std::shared_lock lock(mu_);
  const double dlat = max_radius_m / 110574.0;
  const double dlon = max_radius_m / (111320.0 * std::max(0.01, std::cos(p.lat * 3.14159265358979323846 / 180.0)));
  std::optional<std::uint32_t> best;
  double best_d = max_radius_m;
  for (std::int64_t ix = cell(p.lon - dlon); ix <= cell(p.lon + dlon); ++ix)
    for (std::int64_t iy = cell(p.lat - dlat); iy <= cell(p.lat + dlat); ++iy) {
      auto it = node_cells_.find(key(ix, iy));
      if (it == node_cells_.end()) continue;
      for (std::uint32_t n : it->second) {
        double d = haversine_m(p, graph_.nodes()[n]);
        if (d <= best_d) {
          best_d = d;
          best = n;
        }
      }
    }
  return best;
}

}  // namespace dharani::geo
