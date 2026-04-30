add_library(kintsuki SHARED
  program.cpp
  heuristics.cpp
  libkintsuki.cpp
)

set_target_properties(kintsuki PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
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
  ares::nall::headers
)
