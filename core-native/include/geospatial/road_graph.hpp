#pragma once
// Compact in-memory road network. Loaded from the offline graph file shipped with the app
// (see tools/gen_demo_graph.py and tools/osm_to_graph.py).
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace dharani::geo {

struct LatLon {
  double lat{}, lon{};
};

double haversine_m(LatLon a, LatLon b);
double bearing_deg(LatLon from, LatLon to);

struct Edge {
  std::uint32_t a{}, b{};       // node indices
  float length_m{};
  float speed_kph{50};
  float max_height_m{0};        // 0 = unrestricted
  float max_weight_t{0};        // gross vehicle weight limit, 0 = unrestricted
  float max_axle_t{0};          // axle load limit, 0 = unrestricted
  bool truck_ok{true};
  bool two_wheeler_ok{true};
  bool oneway{false};           // true: travel only a -> b
  bool toll{false};             // FASTag toll plaza on this edge
  std::uint32_t name_id{0};
};

struct Adjacent {
  std::uint32_t edge;
  std::uint32_t to;
};

class RoadGraph {
 public:
  static RoadGraph from_json(std::string_view json_text);
  static RoadGraph load(const std::string& path);

  std::size_t node_count() const { return nodes_.size(); }
  std::size_t edge_count() const { return edges_.size(); }
  const std::vector<LatLon>& nodes() const { return nodes_; }
  const std::vector<Edge>& edges() const { return edges_; }
  const std::vector<Adjacent>& adjacent(std::uint32_t node) const { return adjacency_[node]; }
  const std::string& name(std::uint32_t id) const { return names_[id < names_.size() ? id : 0]; }

 private:
  std::vector<LatLon> nodes_;
  std::vector<Edge> edges_;
  std::vector<std::string> names_;
  std::vector<std::vector<Adjacent>> adjacency_;
};

struct Projection {
  LatLon point;       // closest point on the edge
  double offset_m;    // distance from edge.a along the edge
  double distance_m;  // distance from the query point to `point`
};

Projection project_onto_edge(const RoadGraph& g, std::uint32_t edge, LatLon p);

}  // namespace dharani::geo
