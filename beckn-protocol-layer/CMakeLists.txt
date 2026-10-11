add_library(dharani_protocol STATIC
  src/beckn_b2b_schema.cpp
  src/state_machine.cpp
  src/escrow_reconciliation.cpp)
target_include_directories(dharani_protocol PUBLIC include)
target_link_libraries(dharani_protocol PUBLIC dharani_native)
target_compile_options(dharani_protocol PRIVATE -Wall -Wextra)
