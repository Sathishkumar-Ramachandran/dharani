// iOS exposes the same C ABI through the dharani_ffi framework; Dart binds it with dart:ffi
// (DynamicLibrary.process()). This translation unit keeps the symbols referenced so the linker
// does not dead-strip them from the static archive.
#import <Foundation/Foundation.h>

#include "../dharani_c_api.h"

extern "C" __attribute__((used)) const char* DharaniBridgeVersion(void) {
  return dharani_version();
}

extern "C" __attribute__((used)) void DharaniBridgeKeepSymbols(void) {
  volatile void* keep[] = {
      (void*)&dharani_engine_init,          (void*)&dharani_engine_shutdown,    (void*)&dharani_engine_guard_create,
      (void*)&dharani_engine_guard_release, (void*)&dharani_get_identity,       (void*)&dharani_verify_proof,
      (void*)&dharani_calculate_route,      (void*)&dharani_load_graph,      (void*)&dharani_map_match,          (void*)&dharani_begin_trip,
      (void*)&dharani_process_telemetry_batch, (void*)&dharani_register_mesh_event_callback,
      (void*)&dharani_mesh_start,           (void*)&dharani_mesh_stop,          (void*)&dharani_mesh_publish_hazard,
      (void*)&dharani_mesh_peer_count,      (void*)&dharani_beckn_call,           (void*)&dharani_beckn_take_pending_reply, (void*)&dharani_string_free,
  };
  (void)keep;
}
