#include "routing/valhalla_edge_service.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <stdexcept>

namespace dharani::routing {
namespace {

using geo::Edge;
using geo::LatLon;

struct Costing {
  double max_speed_kph;
  double grams_per_km;
};

Costing costing_params(CostingModel m) {
  switch (m) {
    case CostingModel::Truck: return {70.0, 820.0};
    case CostingModel::TwoWheeler: return {55.0, 45.0};
    case CostingModel::Auto: return {120.0, 130.0};
  }
  return {120.0, 130.0};
}

bool edge_allowed(const Edge& e, CostingModel m, const VehicleProfile& v) {
  switch (m) {
    case CostingModel::Truck:
      if (!e.truck_ok) return false;
      if (e.max_height_m > 0 && v.height_m > 0 && v.height_m > e.max_height_m) return false;
      if (e.max_weight_t > 0 && v.gross_weight_kg > 0 && v.gross_weight_kg / 1000.0 > e.max_weight_t) return false;
      if (e.max_axle_t > 0 && v.axle_load_kg > 0 && v.axle_load_kg / 1000.0 > e.max_axle_t) return false;
      return true;
    case CostingModel::TwoWheeler: return e.two_wheeler_ok;
    case CostingModel::Auto: return true;
  }
  return true;
}

double edge_seconds(const Edge& e, const Costing& c, float factor) {
  double kph = std::min<double>(e.speed_kph, c.max_speed_kph) * std::clamp(factor, 0.1f, 1.0f);
  return e.length_m / (std::max(kph, 3.0) / 3.6);
}

double normalize_turn(double d) {
  while (d > 180) d -= 360;
  while (d < -180) d += 360;
  return d;
}

}  // namespace

ValhallaEdgeService::ValhallaEdgeService(const std::string& tile_dir)
    : ValhallaEdgeService(geo::RoadGraph::load(tile_dir + "/road_graph.json")) {}

ValhallaEdgeService::ValhallaEdgeService(geo::RoadGraph graph) : graph_(std::move(graph)) {
  index_ = std::make_unique<geo::SpatialIndex>(graph_);
  matcher_ = std::make_unique<geo::MapMatcher>(graph_, *index_);
}

std::vector<geo::MatchedPoint> ValhallaEdgeService::MapMatch(const std::vector<RawCoordinate>& trace) const {
  return matcher_->match(trace);
}

Route ValhallaEdgeService::CalculateRoute(double sl, double so, double dl, double dn, CostingModel costing,
                                          const VehicleProfile& vehicle,
                                          const std::vector<float>* factors) const {
  if (!(sl >= -90 && sl <= 90 && dl >= -90 && dl <= 90 && so >= -180 && so <= 180 && dn >= -180 && dn <= 180))
    throw std::invalid_argument("coordinates out of range");
  if (factors != nullptr && factors->size() != graph_.edge_count())
    throw std::invalid_argument("edge speed factor vector has the wrong size");

  const LatLon start{sl, so}, dest{dl, dn};
  constexpr double kSnapRadiusM = 5000;
  auto s = index_->nearest_node(start, kSnapRadiusM);
  auto d = index_->nearest_node(dest, kSnapRadiusM);
  if (!s) throw RoutingError("start is outside the offline map coverage");
  if (!d) throw RoutingError("destination is outside the offline map coverage");

  const Costing c = costing_params(costing);
  const std::size_t n = graph_.node_count();
  const double inf = std::numeric_limits<double>::infinity();
  std::vector<double> cost(n, inf);
  std::vector<std::int64_t> prev_edge(n, -1);
  std::vector<std::uint32_t> prev_node(n, 0);

  struct Item {
    double f;
    std::uint32_t node;
    bool operator>(const Item& o) const { return f > o.f; }
  };
  std::priority_queue<Item, std::vector<Item>, std::greater<>> open;
  const double vmax = c.max_speed_kph / 3.6;
  auto heuristic = [&](std::uint32_t node) { return geo::haversine_m(graph_.nodes()[node], graph_.nodes()[*d]) / vmax; };

  cost[*s] = 0;
  open.push({heuristic(*s), *s});
  while (!open.empty()) {
    auto [f, u] = open.top();
    open.pop();
    if (u == *d) break;
    if (f > cost[u] + heuristic(u) + 1e-9) continue;
    for (const geo::Adjacent& a : graph_.adjacent(u)) {
      const Edge& e = graph_.edges()[a.edge];
      if (!edge_allowed(e, costing, vehicle)) continue;
      double nc = cost[u] + edge_seconds(e, c, factors ? (*factors)[a.edge] : 1.0f);
      if (nc < cost[a.to]) {
        cost[a.to] = nc;
        prev_edge[a.to] = a.edge;
        prev_node[a.to] = u;
        open.push({nc + heuristic(a.to), a.to});
      }
    }
  }
  if (!std::isfinite(cost[*d])) throw RoutingError("no route found for the selected costing and vehicle limits");

  // Reconstruct.
  std::vector<std::uint32_t> nodes, edges;
  for (std::uint32_t v = *d; v != *s; v = prev_node[v]) {
    nodes.push_back(v);
    edges.push_back(static_cast<std::uint32_t>(prev_edge[v]));
  }
  nodes.push_back(*s);
  std::reverse(nodes.begin(), nodes.end());
  std::reverse(edges.begin(), edges.end());

  Route r;
  r.edges = edges;
  r.polyline.push_back(start);
  for (auto v : nodes) r.polyline.push_back(graph_.nodes()[v]);
  r.polyline.push_back(dest);

  double meters = geo::haversine_m(start, graph_.nodes()[*s]) + geo::haversine_m(graph_.nodes()[*d], dest);
  double seconds = meters / (std::min(c.max_speed_kph, 30.0) / 3.6);  // off-graph connectors
  for (auto ei : edges) {
    const Edge& e = graph_.edges()[ei];
    meters += e.length_m;
    seconds += edge_seconds(e, c, factors ? (*factors)[ei] : 1.0f);
    if (e.toll) ++r.toll_plazas;
  }
  r.distance_m = meters;
  r.duration_s = seconds;
  r.carbon_grams = meters / 1000.0 * c.grams_per_km;

  // Turn-by-turn: new instruction when the road name changes or the heading changes by > 35 deg.
  auto name_of = [&](std::uint32_t ei) {
    const std::string& nm = graph_.name(graph_.edges()[ei].name_id);
    return nm.empty() ? std::string("the road") : nm;
  };
  auto turn_word = [](double delta) {
    double a = std::fabs(delta);
    const char* side = delta > 0 ? "right" : "left";
    if (a > 150) return std::string("Make a U-turn");
    if (a > 100) return std::string("Turn sharp ") + side;
    if (a > 60) return std::string("Turn ") + side;
    return std::string("Bear ") + side;
  };

  if (edges.empty()) {
    r.steps.push_back({"You are at the destination", 0, dest});
    return r;
  }
  r.steps.push_back({"Head toward " + name_of(edges[0]), 0, start});
  double leg = 0;
  for (std::size_t i = 0; i < edges.size(); ++i) {
    leg += graph_.edges()[edges[i]].length_m;
    bool last = i + 1 == edges.size();
    if (last) break;
    LatLon p0 = graph_.nodes()[nodes[i]], p1 = graph_.nodes()[nodes[i + 1]], p2 = graph_.nodes()[nodes[i + 2]];
    double turn = normalize_turn(geo::bearing_deg(p1, p2) - geo::bearing_deg(p0, p1));
    bool rename = graph_.edges()[edges[i]].name_id != graph_.edges()[edges[i + 1]].name_id;
    if (rename || std::fabs(turn) > 35) {
      r.steps.back().distance_m = leg;
      leg = 0;
      std::string text = std::fabs(turn) > 35 ? turn_word(turn) + " onto " + name_of(edges[i + 1])
                                              : "Continue onto " + name_of(edges[i + 1]);
      r.steps.push_back({text, 0, p1});
    }
  }
  r.steps.back().distance_m = leg;
  r.steps.push_back({"Arrive at your destination", 0, dest});
  return r;
}

}  // namespace dharani::routing
