#include <cmath>
#include <random>

#include "check.hpp"
#include "gnn/traffic_predictor.hpp"
#include "routing/valhalla_edge_service.hpp"

#ifndef DHARANI_TEST_DATA
#error "DHARANI_TEST_DATA must point at tests/data"
#endif

using namespace dharani;
using routing::CostingModel;

namespace {
bool uses_road(const routing::ValhallaEdgeService& s, const routing::Route& r, const std::string& name) {
  for (auto e : r.edges)
    if (s.graph().name(s.graph().edges()[e].name_id) == name) return true;
  return false;
}
}  // namespace

int main() {
  routing::ValhallaEdgeService svc(DHARANI_TEST_DATA);
  const double blr_lat = 12.9177, blr_lon = 77.6238;      // Silk Board
  const double krish_lat = 12.5186, krish_lon = 78.2137;  // Krishnagiri

  auto car = svc.CalculateRoute(blr_lat, blr_lon, krish_lat, krish_lon, CostingModel::Auto);
  CHECK(car.distance_m > 60000 && car.distance_m < 110000);
  CHECK(car.duration_s > 1800 && car.duration_s < 7200);
  CHECK(car.polyline.size() > 10);
  CHECK(car.steps.size() >= 2);
  CHECK(car.steps.back().instruction.find("Arrive") == 0);
  CHECK(car.toll_plazas >= 1);
  CHECK(uses_road(svc, car, "NH 44"));

  // Truck costing: slower, higher emissions.
  auto truck = svc.CalculateRoute(blr_lat, blr_lon, krish_lat, krish_lon, CostingModel::Truck,
                                  {18000, 8000, 3.2});
  CHECK(truck.duration_s > car.duration_s);
  CHECK(truck.carbon_grams > car.carbon_grams * 3);
  CHECK(uses_road(svc, truck, "NH 44"));

  // A 4.2 m tall truck cannot use the 3.6 m underpass and has to take the bypass...
  auto tall = svc.CalculateRoute(blr_lat, blr_lon, krish_lat, krish_lon, CostingModel::Truck, {18000, 8000, 4.2});
  CHECK(uses_road(svc, tall, "Anekal-Hosur Road"));
  CHECK(tall.distance_m > truck.distance_m);
  // ...and a 25 t one is stopped by the 18 t limit on the bypass: no legal route exists.
  bool threw = false;
  try {
    svc.CalculateRoute(blr_lat, blr_lon, krish_lat, krish_lon, CostingModel::Truck, {25000, 9000, 4.2});
  } catch (const routing::RoutingError&) {
    threw = true;
  }
  CHECK(threw);

  // Two-wheelers are barred from the elevated expressway.
  threw = false;
  try {
    svc.CalculateRoute(blr_lat, blr_lon, 12.7790, 77.7700, CostingModel::TwoWheeler);
  } catch (const routing::RoutingError&) {
    threw = true;
  }
  CHECK(threw);

  // Bad input.
  threw = false;
  try {
    svc.CalculateRoute(95, 0, 0, 0, CostingModel::Auto);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  CHECK(threw);
  threw = false;
  try {
    svc.CalculateRoute(40.0, -100.0, 40.1, -100.1, CostingModel::Auto);  // far outside coverage
  } catch (const routing::RoutingError&) {
    threw = true;
  }
  CHECK(threw);

  // GNN: a congestion hazard on the route slows it down; off-route hazards barely matter.
  gnn::TrafficPredictor gnn;
  auto base = gnn.predict_edge_speed_factors(svc.graph(), 3, {});
  for (float f : base) CHECK(f > 0.95f && f <= 1.0f);
  auto rush = gnn.predict_edge_speed_factors(svc.graph(), 9, {});
  CHECK(rush[0] < base[0]);
  geo::LatLon mid = car.polyline[car.polyline.size() / 2];
  gnn::HazardReport jam{mid, gnn::Hazard::Congestion, 1.0f};
  auto jammed = gnn.predict_edge_speed_factors(svc.graph(), 3, std::span(&jam, 1));
  float min_f = 1;
  for (float f : jammed) min_f = std::min(min_f, f);
  CHECK(min_f < 0.6f);
  auto slow = svc.CalculateRoute(blr_lat, blr_lon, krish_lat, krish_lon, CostingModel::Auto, {}, &jammed);
  CHECK(slow.duration_s > car.duration_s * 1.05);
  CHECK(gnn.predict_speed_kph(std::vector<float>{}) == 0);

  // HMM map matching: noisy GPS along the computed route snaps back to the route's edges.
  std::mt19937 rng(11);
  std::normal_distribution<double> noise(0, 6.0);
  std::vector<routing::RawCoordinate> trace;
  std::vector<std::uint32_t> truth;
  const auto& g = svc.graph();
  for (std::size_t k = 0; k < 40 && k < car.edges.size(); ++k) {
    const auto& e = g.edges()[car.edges[k]];
    geo::LatLon a = g.nodes()[e.a], b = g.nodes()[e.b];
    geo::LatLon p{(a.lat + b.lat) / 2 + noise(rng) / 110574.0, (a.lon + b.lon) / 2 + noise(rng) / 111320.0};
    trace.push_back({p.lat, p.lon, 8.0});
    truth.push_back(car.edges[k]);
  }
  auto matched = svc.MapMatch(trace);
  CHECK_EQ(matched.size(), trace.size());
  std::size_t right = 0;
  for (std::size_t i = 0; i < matched.size(); ++i) {
    if (matched[i].edge_index == static_cast<int>(truth[i])) ++right;
    CHECK(matched[i].confidence >= 0 && matched[i].confidence <= 1);
  }
  CHECK(right >= matched.size() * 95 / 100);

  // A fix far from any road is reported as unmatched, with the raw position retained.
  auto lost = svc.MapMatch({{20.0, 70.0, 10}});
  CHECK_EQ(lost[0].edge_index, -1);
  CHECK_NEAR(lost[0].snapped.lat, 20.0, 1e-9);
  CHECK(svc.MapMatch({}).empty());

  TEST_MAIN_END();
}
