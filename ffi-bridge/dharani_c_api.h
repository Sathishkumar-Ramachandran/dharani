/*
 * Dharani C ABI. Rules of the boundary:
 *  - No C++ exception ever crosses it; every function returns a dharani_status_t (or void).
 *  - The caller owns every buffer it passes in; the library never retains a caller pointer
 *    except the callback + user_data registered with dharani_register_mesh_event_callback.
 *  - Strings are UTF-8, NUL terminated. Output strings are written to caller buffers; when the
 *    buffer is too small DHARANI_BUFFER_TOO_SMALL is returned and *out_len holds the size needed
 *    (excluding the terminating NUL).
 *  - All functions are thread-safe.
 */
#ifndef DHARANI_C_API_H_
#define DHARANI_C_API_H_

#include <stdint.h>

#if defined(__GNUC__)
#define DHARANI_EXPORT __attribute__((visibility("default")))
#else
#define DHARANI_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum {
  DHARANI_OK = 0,
  DHARANI_INVALID_ARGUMENT = 1,
  DHARANI_NOT_INITIALIZED = 2,
  DHARANI_INTERNAL_ERROR = 3,
  DHARANI_NOT_FOUND = 4,
  DHARANI_BUFFER_TOO_SMALL = 5,
  DHARANI_ROUTING_FAILED = 6,
  DHARANI_PROTOCOL_ERROR = 7,
  DHARANI_IO_ERROR = 8
};

typedef struct dharani_status_t {
  int32_t code;           /* one of DHARANI_* */
  char diagnostic[256];   /* human readable, always NUL terminated */
} dharani_status_t;

/* Costing models for dharani_calculate_route. */
enum { DHARANI_COSTING_AUTO = 0, DHARANI_COSTING_TRUCK = 1, DHARANI_COSTING_TWO_WHEELER = 2 };

/* Hazard types, identical to RoadHazardType in proto/telemetry_swarm.fbs. */
enum {
  DHARANI_HAZARD_NONE = 0,
  DHARANI_HAZARD_POTHOLE = 1,
  DHARANI_HAZARD_CONGESTION = 2,
  DHARANI_HAZARD_BLACK_ICE = 3,
  DHARANI_HAZARD_DETOUR = 4,
  DHARANI_HAZARD_STALLED_VEHICLE = 5
};

/* One synchronised GNSS + IMU + CAN-bus + diagnostics sample. NaN temperature = no sensor. */
typedef struct dharani_telemetry_sample_t {
  int64_t timestamp_ns;
  double lat, lon, alt_m, dop, speed_mps, heading_deg, accuracy_m;
  double ax, ay, az;          /* m/s^2, specific force including gravity */
  double gx, gy, gz;          /* rad/s */
  uint64_t odometer_ticks;    /* cumulative wheel ticks */
  double meters_per_tick;
  double temperature_c;
  uint32_t engine_rpm;
  uint32_t obd2_fault_codes;
  float fuel_pct;
  float battery_soc_pct;
  int32_t mock_location;      /* 1 when the OS reports a mock/test location provider */
  int32_t _reserved;
} dharani_telemetry_sample_t;

typedef struct dharani_proof_t {
  uint8_t digest[32];
  uint8_t signature[64];
  uint8_t public_key[32];
  int32_t tamper_flag;
  int32_t tamper_reason;      /* 0 none,1 speed,2 dead-reckoning,3 odometer,4 imu,5 clock,6 mock location */
  int32_t accepted;           /* 1 when the batch was free of tamper */
  int32_t _reserved;
  double filtered_speed_mps;
  double lat, lon;
  int64_t timestamp_ns;
} dharani_proof_t;

typedef struct dharani_match_t {
  int32_t edge_index;         /* -1 = not on the road network */
  int32_t _reserved;
  double lat, lon;            /* snapped position */
  double confidence;          /* 0..1 */
} dharani_match_t;

/* Invoked from a native worker thread with a UTF-8 JSON event:
 * {"type":"hazard"|"peer","vehicle_id":..,"lat":..,"lon":..,"hazard":n,"severity":x,"tamper":bool,...}
 * OWNERSHIP: `json` is heap allocated for the callee, which must release it with
 * dharani_string_free() (this makes the callback safe to forward asynchronously, e.g. through
 * Dart's NativeCallable.listener). */
typedef void (*dharani_mesh_event_callback)(char* json, void* user_data);

/* ---- lifecycle ---- */
DHARANI_EXPORT const char* dharani_version(void);
DHARANI_EXPORT void dharani_string_free(char* s);
/* config_json (may be NULL or "{}"): {"vehicle_id": "...", "graph_path": "...", "mesh_port": 47474} */
DHARANI_EXPORT dharani_status_t dharani_engine_init(const char* storage_path, const char* config_json);
DHARANI_EXPORT dharani_status_t dharani_engine_shutdown(void);
/* A token whose release function shuts the engine down; attach it to a Dart NativeFinalizer. */
DHARANI_EXPORT void* dharani_engine_guard_create(void);
DHARANI_EXPORT void dharani_engine_guard_release(void* guard);

/* ---- identity ---- */
DHARANI_EXPORT dharani_status_t dharani_get_identity(char* vehicle_id_out, uint32_t cap, uint8_t public_key_out[32]);
DHARANI_EXPORT dharani_status_t dharani_verify_proof(const uint8_t public_key[32], const char* trip_id, double lat,
                                                     double lon, int64_t timestamp_ns, int32_t tamper,
                                                     const uint8_t signature[64], int32_t* valid_out);

/* ---- routing ---- */
/* Replaces the road network with the graph file at `graph_path` (the app downloads regions from
 * OpenStreetMap). On failure the previous graph stays active. */
DHARANI_EXPORT dharani_status_t dharani_load_graph(const char* graph_path);
/* hour_of_day < 0 uses the local clock. Output JSON:
 * {"distance_m","duration_s","carbon_grams","toll_plazas","polyline":[[lat,lon]..],"edges":[..],
 *  "steps":[{"instruction","distance_m","lat","lon"}],"tolls":[{"edge","name","lat","lon"}]} */
DHARANI_EXPORT dharani_status_t dharani_calculate_route(double start_lat, double start_lon, double dest_lat,
                                                        double dest_lon, int32_t costing, double gross_weight_kg,
                                                        double axle_load_kg, double height_m, int32_t hour_of_day,
                                                        char* out_json, uint32_t out_cap, uint32_t* out_len);
DHARANI_EXPORT dharani_status_t dharani_map_match(const double* lat_lon_accuracy_triples, uint32_t count,
                                                  dharani_match_t* out);

/* ---- attestation ---- */
DHARANI_EXPORT dharani_status_t dharani_begin_trip(const char* trip_id);
/* Feeds `count` samples (oldest first), returns the signed proof for the last one and, when the
 * mesh is running, broadcasts a signed presence beacon. */
DHARANI_EXPORT dharani_status_t dharani_process_telemetry_batch(const dharani_telemetry_sample_t* samples,
                                                                uint32_t count, dharani_proof_t* out_proof);

/* ---- mesh ---- */
DHARANI_EXPORT dharani_status_t dharani_register_mesh_event_callback(dharani_mesh_event_callback callback,
                                                                     void* user_data);
DHARANI_EXPORT dharani_status_t dharani_mesh_start(void);
DHARANI_EXPORT dharani_status_t dharani_mesh_stop(void);
DHARANI_EXPORT dharani_status_t dharani_mesh_publish_hazard(int32_t hazard, float severity, double lat, double lon);
DHARANI_EXPORT dharani_status_t dharani_mesh_peer_count(uint32_t window_ms, uint32_t* out_count);

/* ---- Beckn B2B protocol ---- */
/* action: search,on_search,select,init,confirm,on_update,on_status,telemetry,dispute,audit.
 * request_json is {"context":{..},"message":{..}}; the reply has the same shape. */
DHARANI_EXPORT dharani_status_t dharani_beckn_call(const char* action, const char* request_json, char* out_json,
                                                   uint32_t out_cap, uint32_t* out_len);

/* Beckn actions change state, so they must not be replayed when the caller's buffer was too
 * small. In that case the reply is parked and DHARANI_BUFFER_TOO_SMALL is returned; fetch it
 * (exactly once) with this call using a buffer of at least *out_len + 1 bytes. */
DHARANI_EXPORT dharani_status_t dharani_beckn_take_pending_reply(char* out_json, uint32_t out_cap, uint32_t* out_len);

#ifdef __cplusplus
}
#endif
#endif /* DHARANI_C_API_H_ */
