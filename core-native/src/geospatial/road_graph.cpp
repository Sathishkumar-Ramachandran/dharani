#include "geospatial/road_graph.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <unordered_map>

#include "util/json.hpp"

namespace dharani::geo {
namespace {
constexpr double kPi = 3.14159265358979323846;
double rad(double d) { return d * kPi / 180.0; }
}  // namespace

double haversine_m(LatLon a, LatLon b) {
  double dlat = rad(b.lat - a.lat), dlon = rad(b.lon - a.lon);
  double h = std::sin(dlat / 2) * std::sin(dlat / 2) +
             std::cos(rad(a.lat)) * std::cos(rad(b.lat)) * std::sin(dlon / 2) * std::sin(dlon / 2);
  return 2 * 6371000.0 * std::atan2(std::sqrt(h), std::sqrt(1 - h));
}

double bearing_deg(LatLon from, LatLon to) {
  double y = std::sin(rad(to.lon - from.lon)) * std::cos(rad(to.lat));
  double x = std::cos(rad(from.lat)) * std::sin(rad(to.lat)) -
             std::sin(rad(from.lat)) * std::cos(rad(to.lat)) * std::cos(rad(to.lon - from.lon));
  double d = std::atan2(y, x) * 180.0 / kPi;
  return d < 0 ? d + 360.0 : d;
}

RoadGraph RoadGraph::load(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("road graph not found: " + path);
  std::stringstream ss;
  ss << in.rdbuf();
  return from_json(ss.str());
}

RoadGraph RoadGraph::from_json(std::string_view text) {
  json::Value root = json::parse(text);
  RoadGraph g;
  g.names_.push_back("");
  std::unordered_map<std::string, std::uint32_t> name_ids;
  name_ids[""] = 0;

  for (const auto& n : root.get("nodes").as_array()) {
    const auto& a = n.as_array();
    if (a.size() < 2) throw std::runtime_error("road graph: node needs [lat, lon]");
    g.nodes_.push_back({a[0].as_number(), a[1].as_number()});
  }
  if (g.nodes_.empty()) throw std::runtime_error("road graph has no nodes");

  for (const auto& e : root.get("edges").as_array()) {
    Edge edge;
    auto a = e.get("a").as_int(), b = e.get("b").as_int();
    if (a < 0 || b < 0 || a >= static_cast<std::int64_t>(g.nodes_.size()) ||
        b >= static_cast<std::int64_t>(g.nodes_.size()) || a == b) {
      throw std::runtime_error("road graph: edge references an invalid node");
    }
    edge.a = static_cast<std::uint32_t>(a);
    edge.b = static_cast<std::uint32_t>(b);
    edge.length_m = static_cast<float>(haversine_m(g.nodes_[edge.a], g.nodes_[edge.b]));
    edge.speed_kph = static_cast<float>(e.get("speed_kph").as_number(50));
    edge.max_height_m = static_cast<float>(e.get("max_height_m").as_number(0));
    edge.max_weight_t = static_cast<float>(e.get("max_weight_t").as_number(0));
    edge.max_axle_t = static_cast<float>(e.get("max_axle_t").as_number(0));
    edge.truck_ok = e.has("truck") ? e.get("truck").as_bool(true) : true;
    edge.two_wheeler_ok = e.has("two_wheeler") ? e.get("two_wheeler").as_bool(true) : true;
    edge.oneway = e.get("oneway").as_bool(false);
    edge.toll = e.get("toll").as_bool(false);
    const std::string& nm = e.get("name").as_string();
    auto it = name_ids.find(nm);
    if (it == name_ids.end()) {
      it = name_ids.emplace(nm, static_cast<std::uint32_t>(g.names_.size())).first;
      g.names_.push_back(nm);
    }
    edge.name_id = it->second;
    g.edges_.push_back(edge);
  }

  g.adjacency_.assign(g.nodes_.size(), {});
  for (std::uint32_t i = 0; i < g.edges_.size(); ++i) {
    const Edge& e = g.edges_[i];
    g.adjacency_[e.a].push_back({i, e.b});
    if (!e.oneway) g.adjacency_[e.b].push_back({i, e.a});
  }
  return g;
}

Projection project_onto_edge(const RoadGraph& g, std::uint32_t edge_idx, LatLon p) {
  const Edge& e = g.edges()[edge_idx];
  LatLon a = g.nodes()[e.a], b = g.nodes()[e.b];
  const double cos_lat = std::cos(rad(p.lat));
  const double mx = 111320.0 * cos_lat, my = 110574.0;
  double ax = (a.lon - p.lon) * mx, ay = (a.lat - p.lat) * my;
  double bx = (b.lon - p.lon) * mx, by = (b.lat - p.lat) * my;
  double dx = bx - ax, dy = by - ay;
  double len2 = dx * dx + dy * dy;
  double t = len2 > 0 ? std::clamp(-(ax * dx + ay * dy) / len2, 0.0, 1.0) : 0.0;
  double px = ax + t * dx, py = ay + t * dy;
  Projection pr;
  pr.point = {p.lat + py / my, p.lon + px / mx};
  pr.offset_m = t * e.length_m;
  pr.distance_m = std::hypot(px, py);
  return pr;
}

}  // namespace dharani::geo
