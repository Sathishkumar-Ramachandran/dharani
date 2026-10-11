add_library(monocypher STATIC
  ${CMAKE_SOURCE_DIR}/third_party/monocypher/monocypher.c
  ${CMAKE_SOURCE_DIR}/third_party/monocypher/monocypher-ed25519.c)
target_include_directories(monocypher PUBLIC ${CMAKE_SOURCE_DIR}/third_party/monocypher)

add_library(dharani_native STATIC
  src/crypto/sha256.cpp
  src/crypto/attestation_engine.cpp
  src/geospatial/road_graph.cpp
  src/geospatial/spatial_index.cpp
  src/geospatial/map_matcher.cpp
  src/routing/valhalla_edge_service.cpp
  src/mesh/telemetry_codec.cpp
  src/mesh/swarm_peer.cpp
  src/mesh/cv2x_sidelink.cpp
  src/gnn/traffic_predictor.cpp)
target_include_directories(dharani_native PUBLIC include)
target_link_libraries(dharani_native PUBLIC monocypher)
target_compile_features(dharani_native PUBLIC cxx_std_20)
target_compile_options(dharani_native PRIVATE -Wall -Wextra)
