#pragma once
// Composition root of the native stack. One Engine exists per process; the C API owns it.
#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "crypto/attestation_engine.hpp"
#include "escrow_reconciliation.hpp"
#include "gnn/traffic_predictor.hpp"
#include "mesh/cv2x_sidelink.hpp"
#include "routing/valhalla_edge_service.hpp"
#include "util/json.hpp"

#include "dharani_c_api.h"

namespace dharani {

struct EngineError : std::runtime_error {
  EngineError(int c, const std::string& m) : std::runtime_error(m), code(c) {}
  int code;
};

class Engine {
 public:
  using EventSink = std::function<void(const std::string& json)>;

  static std::unique_ptr<Engine> create(const std::string& storage_path, const json::Value& config);
  ~Engine();

  const std::string& vehicle_id() const { return vehicle_id_; }
  crypto::PublicKey public_key() const { return attest_->public_key(); }

  std::string calculate_route(double slat, double slon, double dlat, double dlon, int costing, double gross_kg,
                              double axle_kg, double height_m, int hour);
  void load_graph(const std::string& path);
  bool has_graph() const { return router_ != nullptr; }
  void map_match(const double* triples, std::uint32_t n, dharani_match_t* out);

  void begin_trip(const std::string& id);
  dharani_proof_t process_batch(const dharani_telemetry_sample_t* s, std::uint32_t n);

  void set_event_sink(EventSink sink);
  void mesh_start();
  void mesh_stop();
  void publish_hazard(int hazard, float severity, double lat, double lon);
  std::uint32_t peer_count(std::uint32_t window_ms) const;

  std::string beckn(const std::string& action, const std::string& request);
  void park_reply(std::string text);
  std::optional<std::string> take_parked_reply();

 private:
  Engine() = default;
  void on_peer(const mesh::PeerEvent& ev);
  void add_hazard(const gnn::HazardReport& h, std::int64_t now_ns);
  std::vector<gnn::HazardReport> live_hazards(std::int64_t now_ns);

  std::string storage_;
  std::string vehicle_id_;
  std::uint16_t mesh_port_{47474};
  std::unique_ptr<crypto::AttestationEngine> attest_;
  std::unique_ptr<routing::ValhallaEdgeService> router_;
  gnn::TrafficPredictor predictor_;
  beckn::ContractLedger ledger_;

  std::mutex reply_mu_;
  std::optional<std::string> parked_reply_;

  std::mutex hazard_mu_;
  struct Stored {
    gnn::HazardReport report;
    std::int64_t at_ns;
  };
  std::vector<Stored> hazards_;

  std::mutex sink_mu_;
  EventSink sink_;
  std::mutex mesh_mu_;
  std::unique_ptr<mesh::Cv2xSidelink> mesh_;  // declared last: destroyed (threads joined) first
};

}  // namespace dharani
