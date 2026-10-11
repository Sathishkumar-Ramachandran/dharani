// Exercises the exported C ABI exactly the way Dart does.
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "check.hpp"
#include "dharani_c_api.h"
#include "mesh/cv2x_sidelink.hpp"
#include "util/json.hpp"

#ifndef DHARANI_TEST_DATA
#error "DHARANI_TEST_DATA must point at tests/data"
#endif

namespace json = dharani::json;

static std::atomic<int> g_events{0};
static std::atomic<int> g_hazard_events{0};
static void on_event(char* text, void*) {
  ++g_events;
  auto v = json::parse(text);
  if (v.get("type").as_string() == "hazard") ++g_hazard_events;
  dharani_string_free(text);
}

int main() {
  char tmpl[] = "/tmp/dharani_c_api_XXXXXX";
  const char* dir = mkdtemp(tmpl);
  CHECK(dir != nullptr);
  std::string storage = dir;
  std::string cp = "cp " DHARANI_TEST_DATA "/road_graph.json " + storage + "/road_graph.json";
  CHECK(std::system(cp.c_str()) == 0);

  char out[65536];
  uint32_t len = 0;

  // Before init everything reports NOT_INITIALIZED and nothing crashes.
  CHECK_EQ(dharani_calculate_route(1, 1, 2, 2, 0, 0, 0, 0, 3, out, sizeof out, &len).code, DHARANI_NOT_INITIALIZED);
  CHECK_EQ(dharani_begin_trip("t").code, DHARANI_NOT_INITIALIZED);

  CHECK_EQ(dharani_engine_init(nullptr, "{}").code, DHARANI_INVALID_ARGUMENT);
  CHECK_EQ(dharani_engine_init(storage.c_str(), "{not json").code, DHARANI_INVALID_ARGUMENT);
  CHECK_EQ(dharani_engine_init(storage.c_str(), "{\"mesh_port\":80}").code, DHARANI_INVALID_ARGUMENT);
  dharani_status_t st = dharani_engine_init(storage.c_str(), "{\"mesh_port\":47998,\"vehicle_id\":\"veh-c-api-0001\"}");
  CHECK_EQ(st.code, DHARANI_OK);
  if (st.code != DHARANI_OK) std::fprintf(stderr, "init: %s\n", st.diagnostic);

  // Identity is persisted: shutdown + init yields the same public key.
  char vid[64];
  uint8_t pk1[32], pk2[32];
  CHECK_EQ(dharani_get_identity(vid, sizeof vid, pk1).code, DHARANI_OK);
  CHECK_EQ(std::string(vid), "veh-c-api-0001");
  CHECK_EQ(dharani_engine_shutdown().code, DHARANI_OK);
  CHECK_EQ(dharani_engine_init(storage.c_str(), "{\"mesh_port\":47998,\"vehicle_id\":\"veh-c-api-0001\"}").code, DHARANI_OK);
  CHECK_EQ(dharani_get_identity(vid, sizeof vid, pk2).code, DHARANI_OK);
  CHECK(std::memcmp(pk1, pk2, 32) == 0);
  CHECK_EQ(dharani_get_identity(vid, 4, pk2).code, DHARANI_BUFFER_TOO_SMALL);

  // Routing returns JSON and honours buffer limits.
  st = dharani_calculate_route(12.9177, 77.6238, 12.5186, 78.2137, DHARANI_COSTING_TRUCK, 18000, 8000, 3.2, 3,
                               out, sizeof out, &len);
  CHECK_EQ(st.code, DHARANI_OK);
  if (st.code == DHARANI_OK) {
    auto r = json::parse(out);
    CHECK(r.get("distance_m").as_number() > 60000);
    CHECK(r.get("polyline").as_array().size() > 10);
    CHECK(r.get("steps").as_array().size() >= 2);
    CHECK(r.get("carbon_grams").as_number() > 0);
    CHECK(r.get("tolls").as_array().size() >= 1);
    CHECK_EQ(len, std::strlen(out));
  }
  char tiny[16];
  CHECK_EQ(dharani_calculate_route(12.9177, 77.6238, 12.5186, 78.2137, 0, 0, 0, 0, 3, tiny, sizeof tiny, &len).code,
           DHARANI_BUFFER_TOO_SMALL);
  CHECK(len > 16);
  CHECK_EQ(dharani_calculate_route(12.9177, 77.6238, 12.5186, 78.2137, 9, 0, 0, 0, 3, out, sizeof out, &len).code,
           DHARANI_INVALID_ARGUMENT);
  CHECK_EQ(dharani_calculate_route(12.9177, 77.6238, 55.0, 10.0, 0, 0, 0, 0, 3, out, sizeof out, &len).code,
           DHARANI_ROUTING_FAILED);
  CHECK_EQ(dharani_calculate_route(12.9177, 77.6238, 12.5186, 78.2137, 0, 0, 0, 0, 3, nullptr, 0, &len).code,
           DHARANI_INVALID_ARGUMENT);

  // Graph hot-swap: a bad file keeps the old graph, a good one replaces it.
  CHECK_EQ(dharani_load_graph("/nonexistent/graph.json").code, DHARANI_IO_ERROR);
  CHECK_EQ(dharani_load_graph(nullptr).code, DHARANI_INVALID_ARGUMENT);
  CHECK_EQ(dharani_calculate_route(12.9177, 77.6238, 12.5186, 78.2137, 0, 0, 0, 0, 3, out, sizeof out, &len).code, DHARANI_OK);
  CHECK_EQ(dharani_load_graph((storage + "/road_graph.json").c_str()).code, DHARANI_OK);

  // Map matching.
  double trace[9] = {12.9177, 77.6238, 8, 12.9185, 77.6241, 8, 40.0, 40.0, 8};
  dharani_match_t m[3];
  CHECK_EQ(dharani_map_match(trace, 3, m).code, DHARANI_OK);
  CHECK(m[0].edge_index >= 0);
  CHECK_EQ(m[2].edge_index, -1);
  CHECK_EQ(dharani_map_match(nullptr, 3, m).code, DHARANI_INVALID_ARGUMENT);

  // Telemetry + attestation.
  CHECK_EQ(dharani_begin_trip("TRIP-API").code, DHARANI_OK);
  dharani_telemetry_sample_t s[3];
  std::memset(s, 0, sizeof s);
  for (int i = 0; i < 3; ++i) {
    s[i].timestamp_ns = 1'700'000'000'000'000'000LL + i * 1'000'000'000LL;
    s[i].lat = 12.9 + i * 0.00013;
    s[i].lon = 77.6;
    s[i].dop = 1.0;
    s[i].az = 9.80665;
    s[i].meters_per_tick = 0.25;
    s[i].odometer_ticks = static_cast<uint64_t>(i) * 58;
    s[i].temperature_c = 4.0;
  }
  dharani_proof_t proof;
  CHECK_EQ(dharani_process_telemetry_batch(s, 3, &proof).code, DHARANI_OK);
  CHECK_EQ(proof.tamper_flag, 0);
  CHECK_EQ(proof.accepted, 1);
  int32_t valid = 0;
  CHECK_EQ(dharani_verify_proof(proof.public_key, "TRIP-API", proof.lat, proof.lon, proof.timestamp_ns, 0,
                                proof.signature, &valid).code, DHARANI_OK);
  CHECK_EQ(valid, 1);
  CHECK_EQ(dharani_verify_proof(proof.public_key, "TRIP-OTHER", proof.lat, proof.lon, proof.timestamp_ns, 0,
                                proof.signature, &valid).code, DHARANI_OK);
  CHECK_EQ(valid, 0);
  CHECK(std::memcmp(proof.public_key, pk1, 32) == 0);

  // Spoofed jump is flagged and the signed proof carries the flag.
  dharani_telemetry_sample_t spoof = s[2];
  spoof.timestamp_ns += 1'000'000'000LL;
  spoof.lat += 0.5;
  CHECK_EQ(dharani_process_telemetry_batch(&spoof, 1, &proof).code, DHARANI_OK);
  CHECK_EQ(proof.tamper_flag, 1);
  CHECK_EQ(proof.accepted, 0);
  CHECK_EQ(dharani_verify_proof(proof.public_key, "TRIP-API", proof.lat, proof.lon, proof.timestamp_ns, 1,
                                proof.signature, &valid).code, DHARANI_OK);
  CHECK_EQ(valid, 1);
  spoof.lat = 95;
  CHECK_EQ(dharani_process_telemetry_batch(&spoof, 1, &proof).code, DHARANI_INVALID_ARGUMENT);
  CHECK_EQ(dharani_process_telemetry_batch(nullptr, 0, &proof).code, DHARANI_INVALID_ARGUMENT);

  // The OS mock-location indicator raises the flag on its own.
  CHECK_EQ(dharani_begin_trip("TRIP-MOCK").code, DHARANI_OK);
  dharani_telemetry_sample_t mock = s[0];
  mock.timestamp_ns += 10'000'000'000LL;
  mock.mock_location = 1;
  CHECK_EQ(dharani_process_telemetry_batch(&mock, 1, &proof).code, DHARANI_OK);
  CHECK_EQ(proof.tamper_flag, 1);
  CHECK_EQ(proof.tamper_reason, 6);
  CHECK_EQ(dharani_begin_trip("TRIP-API").code, DHARANI_OK);

  // Beckn through the ABI.
  const char* search =
      "{\"context\":{\"transaction_id\":\"api-1\",\"timestamp_ns\":1},\"message\":{\"rfq\":{\"consignor_id\":\"c\","
      "\"origin\":{\"name\":\"a\",\"lat\":12.9,\"lon\":77.6},\"destination\":{\"name\":\"b\",\"lat\":12.5,\"lon\":78.2,"
      "\"radius_m\":300},\"cargo\":{\"volume_m3\":10,\"tonnage\":5},\"delivery_deadline_epoch_s\":2000000000}}}";
  CHECK_EQ(dharani_beckn_call("search", search, out, sizeof out, &len).code, DHARANI_OK);
  CHECK_EQ(json::parse(out).get("message").get("state").as_string(), "DRAFT");
  CHECK_EQ(dharani_beckn_call("search", search, out, sizeof out, &len).code, DHARANI_INVALID_ARGUMENT);  // duplicate
  CHECK_EQ(dharani_beckn_call("confirm", "{\"context\":{\"transaction_id\":\"api-1\"},\"message\":{}}", out,
                              sizeof out, &len).code, DHARANI_PROTOCOL_ERROR);
  // A reply that does not fit is parked, not replayed: the action is applied exactly once.
  const char* search2 = "{\"context\":{\"transaction_id\":\"api-2\",\"timestamp_ns\":1},\"message\":{\"rfq\":{\"consignor_id\":\"c\","
      "\"origin\":{\"name\":\"a\",\"lat\":12.9,\"lon\":77.6},\"destination\":{\"name\":\"b\",\"lat\":12.5,\"lon\":78.2},"
      "\"cargo\":{\"volume_m3\":10,\"tonnage\":5},\"delivery_deadline_epoch_s\":2000000000}}}";
  char small[32];
  CHECK_EQ(dharani_beckn_call("search", search2, small, sizeof small, &len).code, DHARANI_BUFFER_TOO_SMALL);
  CHECK(len > sizeof small);
  CHECK_EQ(dharani_beckn_take_pending_reply(small, sizeof small, &len).code, DHARANI_BUFFER_TOO_SMALL);
  CHECK_EQ(dharani_beckn_take_pending_reply(out, sizeof out, &len).code, DHARANI_OK);
  CHECK_EQ(json::parse(out).get("context").get("transaction_id").as_string(), "api-2");
  CHECK_EQ(dharani_beckn_take_pending_reply(out, sizeof out, &len).code, DHARANI_NOT_FOUND);
  CHECK_EQ(dharani_beckn_call("search", search2, out, sizeof out, &len).code, DHARANI_INVALID_ARGUMENT);  // exists once
  CHECK_EQ(dharani_beckn_call("search", "garbage", out, sizeof out, &len).code, DHARANI_INVALID_ARGUMENT);

  // Mesh: start, publish a hazard, receive it back through the callback (loopback).
  CHECK_EQ(dharani_register_mesh_event_callback(on_event, nullptr).code, DHARANI_OK);
  st = dharani_mesh_start();
  if (st.code == DHARANI_OK) {
    CHECK_EQ(dharani_mesh_publish_hazard(99, 0.5f, 12.8, 77.7).code, DHARANI_INVALID_ARGUMENT);
    CHECK_EQ(dharani_mesh_publish_hazard(DHARANI_HAZARD_POTHOLE, 1.5f, 12.8, 77.7).code, DHARANI_INVALID_ARGUMENT);
    CHECK_EQ(dharani_mesh_publish_hazard(DHARANI_HAZARD_POTHOLE, 0.5f, 12.8, 77.7).code, DHARANI_OK);
    // Own frames are ignored by design, so no event is expected; the hazard is still recorded and
    // slows routing through that area.
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    CHECK_EQ(g_hazard_events.load(), 0);
    {  // A different vehicle's hazard arrives through the callback and is owned by the callee.
      dharani::crypto::AttestationEngine other;
      dharani::mesh::SwarmMessage hm;
      hm.set_vehicle("other-vehicle-0002");
      hm.lat = 12.8; hm.lon = 77.7; hm.hazard = dharani::gnn::Hazard::Congestion; hm.severity = 0.9f;
      dharani::mesh::Cv2xSidelink tx(47998);
      std::string e2;
      if (tx.start([](const dharani::mesh::PeerEvent&) {}, "other-vehicle-0002", &e2)) {
        for (int i = 0; i < 30 && g_hazard_events.load() == 0; ++i) {
          tx.publish(dharani::mesh::encode_signed(hm, other));
          std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        CHECK(g_hazard_events.load() >= 1);
      }
    }
    uint32_t peers = 99;
    CHECK_EQ(dharani_mesh_peer_count(5000, &peers).code, DHARANI_OK);
    CHECK(peers <= 1u);
    CHECK_EQ(dharani_mesh_stop().code, DHARANI_OK);
  } else {
    std::fprintf(stderr, "note: mesh start skipped: %s\n", st.diagnostic);
  }
  CHECK_EQ(dharani_register_mesh_event_callback(nullptr, nullptr).code, DHARANI_OK);

  CHECK(std::strlen(dharani_version()) > 0);
  void* guard = dharani_engine_guard_create();
  CHECK(guard != nullptr);
  dharani_engine_guard_release(guard);  // shuts the engine down
  CHECK_EQ(dharani_begin_trip("t").code, DHARANI_NOT_INITIALIZED);
  CHECK_EQ(dharani_engine_shutdown().code, DHARANI_OK);  // idempotent

  std::string rm = "rm -rf " + storage;
  (void)std::system(rm.c_str());
  TEST_MAIN_END();
}
