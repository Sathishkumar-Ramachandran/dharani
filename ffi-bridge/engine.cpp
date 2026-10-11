#include "engine.hpp"

#include <sys/stat.h>

#include <chrono>
#include <cmath>
#include <ctime>
#include <fstream>

#include "crypto/sha256.hpp"

namespace dharani {
namespace {

std::int64_t mono_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

constexpr std::int64_t kHazardTtlNs = 30LL * 60 * 1000000000LL;

std::string uuid_from_key(const crypto::PublicKey& pk) {
  auto h = crypto::Sha256::hash(std::span<const std::uint8_t>(pk.data(), pk.size()));
  std::string hex = crypto::to_hex(std::span<const std::uint8_t>(h.data(), 16));
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" + hex.substr(12, 4) + "-" + hex.substr(16, 4) + "-" +
         hex.substr(20, 12);
}

json::Value ll(const geo::LatLon& p) {
  json::Value a = json::Value::array();
  a.push(p.lat).push(p.lon);
  return a;
}

}  // namespace

std::unique_ptr<Engine> Engine::create(const std::string& storage_path, const json::Value& config) {
  std::unique_ptr<Engine> e(new Engine);
  e->storage_ = storage_path;
  ::mkdir(storage_path.c_str(), 0700);
  struct stat st{};
  if (::stat(storage_path.c_str(), &st) != 0 || !S_ISDIR(st.st_mode))
    throw EngineError(DHARANI_IO_ERROR, "storage_path is not a directory: " + storage_path);

  std::array<std::uint8_t, 32> seed{};
  std::string err;
  if (!crypto::AttestationEngine::load_or_create_seed(storage_path + "/device_key.bin", seed, err))
    throw EngineError(DHARANI_IO_ERROR, err);
  e->attest_ = std::make_unique<crypto::AttestationEngine>(seed);

  e->vehicle_id_ = config.get("vehicle_id").as_string();
  if (e->vehicle_id_.empty()) e->vehicle_id_ = uuid_from_key(e->attest_->public_key());
  if (e->vehicle_id_.size() > 36) throw EngineError(DHARANI_INVALID_ARGUMENT, "vehicle_id longer than 36 bytes");
  if (config.has("mesh_port")) {
    auto p = config.get("mesh_port").as_int();
    if (p < 1024 || p > 65535) throw EngineError(DHARANI_INVALID_ARGUMENT, "mesh_port out of range");
    e->mesh_port_ = static_cast<std::uint16_t>(p);
  }

  std::string graph_path = config.get("graph_path").as_string();
  if (graph_path.empty()) graph_path = storage_path + "/road_graph.json";
  std::ifstream probe(graph_path);
  if (probe.good()) {
    try {
      e->router_ = std::make_unique<routing::ValhallaEdgeService>(geo::RoadGraph::load(graph_path));
    } catch (const std::exception& ex) {
      throw EngineError(DHARANI_IO_ERROR, std::string("cannot load road graph: ") + ex.what());
    }
  }
  return e;
}

Engine::~Engine() { mesh_stop(); }

std::vector<gnn::HazardReport> Engine::live_hazards(std::int64_t now_ns) {
  std::lock_guard lock(hazard_mu_);
  std::erase_if(hazards_, [&](const Stored& s) { return now_ns - s.at_ns > kHazardTtlNs; });
  std::vector<gnn::HazardReport> out;
  out.reserve(hazards_.size());
  for (const auto& s : hazards_) out.push_back(s.report);
  return out;
}

void Engine::add_hazard(const gnn::HazardReport& h, std::int64_t now_ns) {
  std::lock_guard lock(hazard_mu_);
  if (hazards_.size() >= 256) hazards_.erase(hazards_.begin());
  hazards_.push_back({h, now_ns});
}

std::string Engine::calculate_route(double slat, double slon, double dlat, double dlon, int costing, double gross_kg,
                                    double axle_kg, double height_m, int hour) {
  if (!router_) throw EngineError(DHARANI_NOT_FOUND, "no road graph installed in the storage directory");
  if (costing < 0 || costing > 2) throw EngineError(DHARANI_INVALID_ARGUMENT, "unknown costing model");
  if (hour < 0) {
    std::time_t t = std::time(nullptr);
    std::tm lt{};
    localtime_r(&t, &lt);
    hour = lt.tm_hour;
  }
  auto hazards = live_hazards(mono_ns());
  std::vector<float> factors = predictor_.predict_edge_speed_factors(router_->graph(), hour, hazards);
  routing::VehicleProfile v{gross_kg, axle_kg, height_m};
  routing::Route r;
  try {
    r = router_->CalculateRoute(slat, slon, dlat, dlon, static_cast<routing::CostingModel>(costing), v, &factors);
  } catch (const routing::RoutingError& ex) {
    throw EngineError(DHARANI_ROUTING_FAILED, ex.what());
  }
  json::Value out = json::Value::object();
  out.set("distance_m", r.distance_m).set("duration_s", r.duration_s).set("carbon_grams", r.carbon_grams);
  out.set("toll_plazas", r.toll_plazas);
  json::Value poly = json::Value::array();
  for (const auto& p : r.polyline) poly.push(ll(p));
  out.set("polyline", poly);
  json::Value edges = json::Value::array();
  for (auto e : r.edges) edges.push(static_cast<std::int64_t>(e));
  out.set("edges", edges);
  json::Value steps = json::Value::array();
  for (const auto& s : r.steps) {
    json::Value st = json::Value::object();
    st.set("instruction", s.instruction).set("distance_m", s.distance_m).set("lat", s.at.lat).set("lon", s.at.lon);
    steps.push(st);
  }
  out.set("steps", steps);
  json::Value tolls = json::Value::array();
  const auto& g = router_->graph();
  for (auto ei : r.edges) {
    const auto& e = g.edges()[ei];
    if (!e.toll) continue;
    const auto& a = g.nodes()[e.a];
    const auto& b = g.nodes()[e.b];
    json::Value t = json::Value::object();
    t.set("edge", static_cast<std::int64_t>(ei)).set("name", g.name(e.name_id));
    t.set("lat", (a.lat + b.lat) / 2).set("lon", (a.lon + b.lon) / 2);
    tolls.push(t);
  }
  out.set("tolls", tolls);
  return json::dump(out);
}

void Engine::load_graph(const std::string& path) {
  try {
    auto fresh = std::make_unique<routing::ValhallaEdgeService>(geo::RoadGraph::load(path));
    router_ = std::move(fresh);
  } catch (const std::exception& ex) {
    throw EngineError(DHARANI_IO_ERROR, std::string("cannot load road graph: ") + ex.what());
  }
}

void Engine::map_match(const double* t, std::uint32_t n, dharani_match_t* out) {
  if (!router_) throw EngineError(DHARANI_NOT_FOUND, "no road graph installed in the storage directory");
  std::vector<routing::RawCoordinate> trace(n);
  for (std::uint32_t i = 0; i < n; ++i) trace[i] = {t[3 * i], t[3 * i + 1], t[3 * i + 2] > 0 ? t[3 * i + 2] : 10.0};
  auto m = router_->MapMatch(trace);
  for (std::uint32_t i = 0; i < n; ++i) {
    out[i].edge_index = m[i].edge_index;
    out[i]._reserved = 0;
    out[i].lat = m[i].snapped.lat;
    out[i].lon = m[i].snapped.lon;
    out[i].confidence = m[i].confidence;
  }
}

void Engine::begin_trip(const std::string& id) {
  if (id.empty()) throw EngineError(DHARANI_INVALID_ARGUMENT, "trip_id is empty");
  attest_->begin_trip(id);
}

dharani_proof_t Engine::process_batch(const dharani_telemetry_sample_t* s, std::uint32_t n) {
  bool accepted = true;
  for (std::uint32_t i = 0; i < n; ++i) {
    crypto::GnssSample g{s[i].lat, s[i].lon, s[i].alt_m, s[i].dop, s[i].speed_mps, s[i].heading_deg, s[i].timestamp_ns};
    crypto::ImuSample imu{s[i].ax, s[i].ay, s[i].az, s[i].gx, s[i].gy, s[i].gz, s[i].timestamp_ns};
    crypto::OdometerSample odo{s[i].odometer_ticks, s[i].meters_per_tick, s[i].timestamp_ns};
    if (s[i].mock_location != 0) attest_->flag_external(crypto::TamperReason::MockLocation);
    accepted = attest_->ingest(g, imu, odo) && accepted;
  }
  const dharani_telemetry_sample_t& last = s[n - 1];
  crypto::GnssSample at{last.lat, last.lon, last.alt_m, last.dop, last.speed_mps, last.heading_deg, last.timestamp_ns};
  crypto::Proof p = attest_->prove(at);

  dharani_proof_t out{};
  std::copy(p.digest.begin(), p.digest.end(), out.digest);
  std::copy(p.signature.begin(), p.signature.end(), out.signature);
  std::copy(p.public_key.begin(), p.public_key.end(), out.public_key);
  out.tamper_flag = p.tamper_flag ? 1 : 0;
  out.tamper_reason = static_cast<int32_t>(p.reason);
  out.accepted = accepted ? 1 : 0;
  out.filtered_speed_mps = attest_->filtered_speed_mps();
  out.lat = last.lat;
  out.lon = last.lon;
  out.timestamp_ns = last.timestamp_ns;

  // Presence beacon (hazard NONE) so neighbours can see this vehicle and its tamper state.
  std::lock_guard lock(mesh_mu_);
  if (mesh_ && mesh_->running()) {
    mesh::SwarmMessage m;
    m.set_vehicle(vehicle_id_);
    m.timestamp_ns = static_cast<std::uint64_t>(last.timestamp_ns);
    m.lat = last.lat;
    m.lon = last.lon;
    m.alt = static_cast<float>(last.alt_m);
    m.heading = static_cast<float>(last.heading_deg);
    m.speed = static_cast<float>(last.speed_mps);
    m.accuracy = static_cast<float>(last.accuracy_m);
    m.engine_rpm = last.engine_rpm;
    m.fuel_pct = last.fuel_pct;
    m.fault_codes = last.obd2_fault_codes;
    m.battery_soc_pct = last.battery_soc_pct;
    m.tamper = p.tamper_flag;
    auto dg = mesh::encode_signed(m, *attest_);
    mesh_->publish(dg);
  }
  return out;
}

void Engine::set_event_sink(EventSink sink) {
  std::lock_guard lock(sink_mu_);
  sink_ = std::move(sink);
}

void Engine::on_peer(const mesh::PeerEvent& ev) {
  const auto& m = ev.message;
  if (m.hazard != gnn::Hazard::None) add_hazard({{m.lat, m.lon}, m.hazard, m.severity}, mono_ns());
  json::Value j = json::Value::object();
  j.set("type", m.hazard == gnn::Hazard::None ? "peer" : "hazard");
  j.set("vehicle_id", m.vehicle()).set("lat", m.lat).set("lon", m.lon);
  j.set("hazard", static_cast<int>(m.hazard)).set("severity", static_cast<double>(m.severity));
  j.set("speed", static_cast<double>(m.speed)).set("heading", static_cast<double>(m.heading));
  j.set("tamper", m.tamper).set("rssi", ev.rssi_dbm);
  std::string text = json::dump(j);
  std::lock_guard lock(sink_mu_);
  if (sink_) sink_(text);
}

void Engine::mesh_start() {
  std::lock_guard lock(mesh_mu_);
  if (mesh_ && mesh_->running()) return;
  mesh_ = std::make_unique<mesh::Cv2xSidelink>(mesh_port_);
  std::string err;
  if (!mesh_->start([this](const mesh::PeerEvent& ev) { on_peer(ev); }, vehicle_id_, &err)) {
    mesh_.reset();
    throw EngineError(DHARANI_IO_ERROR, "mesh start failed: " + err);
  }
}

void Engine::mesh_stop() {
  std::unique_ptr<mesh::Cv2xSidelink> m;
  {
    std::lock_guard lock(mesh_mu_);
    m = std::move(mesh_);
  }
  if (m) m->stop();
}

void Engine::publish_hazard(int hazard, float severity, double lat, double lon) {
  if (hazard < 1 || hazard > 5) throw EngineError(DHARANI_INVALID_ARGUMENT, "hazard type out of range");
  if (!(severity >= 0.f && severity <= 1.f)) throw EngineError(DHARANI_INVALID_ARGUMENT, "severity must be in 0..1");
  if (!(lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180))
    throw EngineError(DHARANI_INVALID_ARGUMENT, "coordinates out of range");
  add_hazard({{lat, lon}, static_cast<gnn::Hazard>(hazard), severity}, mono_ns());
  std::lock_guard lock(mesh_mu_);
  if (!mesh_ || !mesh_->running()) return;  // recorded locally; nothing to broadcast to
  mesh::SwarmMessage m;
  m.set_vehicle(vehicle_id_);
  m.timestamp_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                  std::chrono::system_clock::now().time_since_epoch())
                                                  .count());
  m.lat = lat;
  m.lon = lon;
  m.hazard = static_cast<gnn::Hazard>(hazard);
  m.severity = severity;
  m.tamper = attest_->tamper_flag();
  mesh_->publish(mesh::encode_signed(m, *attest_));
}

std::uint32_t Engine::peer_count(std::uint32_t window_ms) const {
  // mesh_mu_ guards the pointer; the table itself is internally synchronised.
  auto* self = const_cast<Engine*>(this);
  std::lock_guard lock(self->mesh_mu_);
  if (!mesh_ || !mesh_->running()) return 0;
  return static_cast<std::uint32_t>(mesh_->peers().active_count(mono_ns(), static_cast<std::int64_t>(window_ms) * 1000000LL));
}

void Engine::park_reply(std::string text) {
  std::lock_guard lock(reply_mu_);
  parked_reply_ = std::move(text);
}

std::optional<std::string> Engine::take_parked_reply() {
  std::lock_guard lock(reply_mu_);
  auto out = std::move(parked_reply_);
  parked_reply_.reset();
  return out;
}

std::string Engine::beckn(const std::string& action, const std::string& request) {
  json::Value req = json::parse(request);
  return json::dump(ledger_.handle(action, req));
}

}  // namespace dharani
