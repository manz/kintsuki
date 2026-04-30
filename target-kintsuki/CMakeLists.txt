add_library(kintsuki SHARED
  program.cpp
  heuristics.cpp
  libkintsuki.cpp
)

set_target_properties(kintsuki PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
  # ares applies -fvisibility=hidden globally; override for our extern "C"
  # symbols so the shared library actually exposes them.
  CXX_VISIBILITY_PRESET default
  C_VISIBILITY_PRESET default
  VISIBILITY_INLINES_HIDDEN OFF
  OUTPUT_NAME kintsuki
  PREFIX "lib"
)

# Default location of ares' System/ directory tree (boards.bml + ipl.rom).
target_compile_definitions(kintsuki PRIVATE
  KINTSUKI_SYSTEM_PAK_DEFAULT="${CMAKE_SOURCE_DIR}/ares/System/Super Famicom"
)

target_include_directories(kintsuki PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}
  ${CMAKE_SOURCE_DIR}/ares
  ${CMAKE_SOURCE_DIR}/nall
)

target_link_libraries(kintsuki PRIVATE
  ares::ares
  ares::nall
)

# ares sets -fvisibility=hidden on its targets; we need our extern "C"
# C-ABI symbols visible on the shared library boundary.
target_compile_options(kintsuki PRIVATE -fvisibility=default)
