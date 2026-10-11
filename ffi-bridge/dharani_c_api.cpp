#include "dharani_c_api.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <shared_mutex>
#include <string>

#include "crypto/attestation_engine.hpp"
#include "engine.hpp"

namespace {

std::shared_mutex g_mu;
std::unique_ptr<dharani::Engine> g_engine;  // guarded by g_mu

std::mutex g_cb_mu;
dharani_mesh_event_callback g_cb = nullptr;
void* g_cb_user = nullptr;

dharani_status_t make_status(int code, const std::string& msg) {
  dharani_status_t s;
  std::memset(&s, 0, sizeof s);
  s.code = code;
  std::snprintf(s.diagnostic, sizeof s.diagnostic, "%s", msg.c_str());
  return s;
}
dharani_status_t ok(const char* msg = "ok") { return make_status(DHARANI_OK, msg); }

// Runs `fn` with the engine under a shared lock; converts every exception into a status.
template <typename Fn>
dharani_status_t with_engine(Fn&& fn) noexcept {
  try {
    std::shared_lock lock(g_mu);
    if (!g_engine) return make_status(DHARANI_NOT_INITIALIZED, "engine not initialized");
    fn(*g_engine);
    return ok();
  } catch (const dharani::EngineError& e) {
    return make_status(e.code, e.what());
  } catch (const dharani::json::ParseError& e) {
    return make_status(DHARANI_INVALID_ARGUMENT, e.what());
  } catch (const std::invalid_argument& e) {
    return make_status(DHARANI_INVALID_ARGUMENT, e.what());
  } catch (const std::logic_error& e) {
    return make_status(DHARANI_PROTOCOL_ERROR, e.what());
  } catch (const std::exception& e) {
    return make_status(DHARANI_INTERNAL_ERROR, e.what());
  } catch (...) {
    return make_status(DHARANI_INTERNAL_ERROR, "unknown native failure");
  }
}

dharani_status_t write_out(const std::string& text, char* out, uint32_t cap, uint32_t* len) {
  if (len) *len = static_cast<uint32_t>(text.size());
  if (!out || cap < text.size() + 1) return make_status(DHARANI_BUFFER_TOO_SMALL, "output buffer too small");
  std::memcpy(out, text.c_str(), text.size() + 1);
  return ok();
}

void forward_event(const std::string& json) {
  std::lock_guard lock(g_cb_mu);
  if (!g_cb) return;
  char* copy = static_cast<char*>(std::malloc(json.size() + 1));
  if (!copy) return;
  std::memcpy(copy, json.c_str(), json.size() + 1);
  g_cb(copy, g_cb_user);  // ownership passes to the callee
}

}  // namespace

extern "C" {

const char* dharani_version(void) { return "dharani-core 0.2.0"; }
void dharani_string_free(char* s) { std::free(s); }

dharani_status_t dharani_engine_init(const char* storage_path, const char* config_json) {
  if (!storage_path || !*storage_path) return make_status(DHARANI_INVALID_ARGUMENT, "storage_path is required");
  try {
    dharani::json::Value cfg = (config_json && *config_json) ? dharani::json::parse(config_json)
                                                              : dharani::json::Value::object();
    auto engine = dharani::Engine::create(storage_path, cfg);
    engine->set_event_sink(forward_event);
    std::unique_lock lock(g_mu);
    g_engine = std::move(engine);
    return ok("ready");
  } catch (const dharani::EngineError& e) {
    return make_status(e.code, e.what());
  } catch (const dharani::json::ParseError& e) {
    return make_status(DHARANI_INVALID_ARGUMENT, e.what());
  } catch (const std::exception& e) {
    return make_status(DHARANI_INTERNAL_ERROR, e.what());
  } catch (...) {
    return make_status(DHARANI_INTERNAL_ERROR, "unknown native failure");
  }
}

dharani_status_t dharani_engine_shutdown(void) {
  try {
    std::unique_ptr<dharani::Engine> doomed;
    {
      std::unique_lock lock(g_mu);
      doomed = std::move(g_engine);
    }
    doomed.reset();  // joins mesh threads outside the lock
    return ok("stopped");
  } catch (...) {
    return make_status(DHARANI_INTERNAL_ERROR, "shutdown failed");
  }
}

void* dharani_engine_guard_create(void) { return new (std::nothrow) unsigned char(0); }
void dharani_engine_guard_release(void* guard) {
  if (!guard) return;
  delete static_cast<unsigned char*>(guard);
  (void)dharani_engine_shutdown();
}

dharani_status_t dharani_get_identity(char* vehicle_id_out, uint32_t cap, uint8_t public_key_out[32]) {
  if (!vehicle_id_out || !public_key_out) return make_status(DHARANI_INVALID_ARGUMENT, "null output");
  return with_engine([&](dharani::Engine& e) {
    uint32_t n = 0;
    auto st = write_out(e.vehicle_id(), vehicle_id_out, cap, &n);
    if (st.code != DHARANI_OK) throw dharani::EngineError(st.code, st.diagnostic);
    auto pk = e.public_key();
    std::memcpy(public_key_out, pk.data(), 32);
  });
}

dharani_status_t dharani_verify_proof(const uint8_t public_key[32], const char* trip_id, double lat, double lon,
                                      int64_t timestamp_ns, int32_t tamper, const uint8_t signature[64],
                                      int32_t* valid_out) {
  if (!public_key || !trip_id || !signature || !valid_out)
    return make_status(DHARANI_INVALID_ARGUMENT, "null argument");
  try {
    dharani::crypto::PublicKey pk;
    dharani::crypto::Signature sig;
    std::memcpy(pk.data(), public_key, 32);
    std::memcpy(sig.data(), signature, 64);
    *valid_out = dharani::crypto::verify_proof(pk, trip_id, lat, lon, timestamp_ns, tamper != 0, sig) ? 1 : 0;
    return ok();
  } catch (...) {
    return make_status(DHARANI_INTERNAL_ERROR, "verification failed");
  }
}

dharani_status_t dharani_load_graph(const char* graph_path) {
  if (!graph_path || !*graph_path) return make_status(DHARANI_INVALID_ARGUMENT, "graph_path is required");
  try {
    std::unique_lock lock(g_mu);  // exclusive: no route or match call may be using the old graph
    if (!g_engine) return make_status(DHARANI_NOT_INITIALIZED, "engine not initialized");
    g_engine->load_graph(graph_path);
    return ok("graph loaded");
  } catch (const dharani::EngineError& e) {
    return make_status(e.code, e.what());
  } catch (const std::exception& e) {
    return make_status(DHARANI_INTERNAL_ERROR, e.what());
  } catch (...) {
    return make_status(DHARANI_INTERNAL_ERROR, "unknown native failure");
  }
}

dharani_status_t dharani_calculate_route(double slat, double slon, double dlat, double dlon, int32_t costing,
                                         double gross_weight_kg, double axle_load_kg, double height_m,
                                         int32_t hour_of_day, char* out_json, uint32_t out_cap, uint32_t* out_len) {
  if (!out_json || out_cap == 0) return make_status(DHARANI_INVALID_ARGUMENT, "output buffer required");
  return with_engine([&](dharani::Engine& e) {
    std::string text = e.calculate_route(slat, slon, dlat, dlon, costing, gross_weight_kg, axle_load_kg, height_m,
                                         hour_of_day);
    auto st = write_out(text, out_json, out_cap, out_len);
    if (st.code != DHARANI_OK) throw dharani::EngineError(st.code, st.diagnostic);
  });
}

dharani_status_t dharani_map_match(const double* triples, uint32_t count, dharani_match_t* out) {
  if (!triples || !out || count == 0) return make_status(DHARANI_INVALID_ARGUMENT, "empty trace");
  return with_engine([&](dharani::Engine& e) { e.map_match(triples, count, out); });
}

dharani_status_t dharani_begin_trip(const char* trip_id) {
  if (!trip_id) return make_status(DHARANI_INVALID_ARGUMENT, "trip_id is null");
  return with_engine([&](dharani::Engine& e) { e.begin_trip(trip_id); });
}

dharani_status_t dharani_process_telemetry_batch(const dharani_telemetry_sample_t* samples, uint32_t count,
                                                 dharani_proof_t* out_proof) {
  if (!samples || count == 0 || !out_proof) return make_status(DHARANI_INVALID_ARGUMENT, "empty telemetry batch");
  for (uint32_t i = 0; i < count; ++i) {
    const auto& s = samples[i];
    if (!std::isfinite(s.lat) || !std::isfinite(s.lon) || std::fabs(s.lat) > 90 || std::fabs(s.lon) > 180)
      return make_status(DHARANI_INVALID_ARGUMENT, "sample has invalid coordinates");
  }
  return with_engine([&](dharani::Engine& e) { *out_proof = e.process_batch(samples, count); });
}

dharani_status_t dharani_register_mesh_event_callback(dharani_mesh_event_callback callback, void* user_data) {
  std::lock_guard lock(g_cb_mu);
  g_cb = callback;
  g_cb_user = user_data;
  return ok(callback ? "callback registered" : "callback cleared");
}

dharani_status_t dharani_mesh_start(void) {
  return with_engine([](dharani::Engine& e) { e.mesh_start(); });
}
dharani_status_t dharani_mesh_stop(void) {
  return with_engine([](dharani::Engine& e) { e.mesh_stop(); });
}
dharani_status_t dharani_mesh_publish_hazard(int32_t hazard, float severity, double lat, double lon) {
  return with_engine([&](dharani::Engine& e) { e.publish_hazard(hazard, severity, lat, lon); });
}
dharani_status_t dharani_mesh_peer_count(uint32_t window_ms, uint32_t* out_count) {
  if (!out_count) return make_status(DHARANI_INVALID_ARGUMENT, "out_count is null");
  return with_engine([&](dharani::Engine& e) { *out_count = e.peer_count(window_ms); });
}

dharani_status_t dharani_beckn_call(const char* action, const char* request_json, char* out_json, uint32_t out_cap,
                                    uint32_t* out_len) {
  if (!action || !request_json || !out_json || out_cap == 0)
    return make_status(DHARANI_INVALID_ARGUMENT, "action, request and output buffer are required");
  return with_engine([&](dharani::Engine& e) {
    std::string text = e.beckn(action, request_json);
    auto st = write_out(text, out_json, out_cap, out_len);
    if (st.code == DHARANI_BUFFER_TOO_SMALL) e.park_reply(std::move(text));  // the action already took effect
    if (st.code != DHARANI_OK) throw dharani::EngineError(st.code, st.diagnostic);
  });
}

dharani_status_t dharani_beckn_take_pending_reply(char* out_json, uint32_t out_cap, uint32_t* out_len) {
  if (!out_json || out_cap == 0) return make_status(DHARANI_INVALID_ARGUMENT, "output buffer required");
  return with_engine([&](dharani::Engine& e) {
    auto text = e.take_parked_reply();
    if (!text) throw dharani::EngineError(DHARANI_NOT_FOUND, "no pending reply");
    auto st = write_out(*text, out_json, out_cap, out_len);
    if (st.code == DHARANI_BUFFER_TOO_SMALL) e.park_reply(std::move(*text));  // keep it for the next attempt
    if (st.code != DHARANI_OK) throw dharani::EngineError(st.code, st.diagnostic);
  });
}

}  // extern "C"
