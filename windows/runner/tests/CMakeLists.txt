cmake_minimum_required(VERSION 3.14)
project(jms_update_tests LANGUAGES CXX)
add_executable(jms_update_test desktop_update_test.cpp)
target_compile_features(jms_update_test PRIVATE cxx_std_17)
target_compile_definitions(jms_update_test PRIVATE FLUTTER_VERSION_BUILD=0 NOMINMAX UNICODE _UNICODE)
target_include_directories(jms_update_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../flutter/ephemeral/cpp_client_wrapper/include" "${CMAKE_CURRENT_SOURCE_DIR}/../../flutter/ephemeral")
target_link_libraries(jms_update_test PRIVATE version wintrust shell32)

# Compile the isolated-root contract for both formal and TEST runner modes.
# The executable accepts an empty, synthetic fixture directory. Link fixtures
# are mandatory by default; --skip-link-fixtures is only for restricted sandboxes.
foreach(profile_build IN ITEMS 0 1)
  add_executable(jms_profile_test_${profile_build}
    test_profile_test.cpp
    ../test_profile.cpp)
  target_compile_features(jms_profile_test_${profile_build} PRIVATE cxx_std_17)
  target_compile_definitions(jms_profile_test_${profile_build} PRIVATE
    JMS_TEST_PROFILE_BUILD=${profile_build} NOMINMAX UNICODE _UNICODE)
  target_include_directories(jms_profile_test_${profile_build} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/..")
  target_link_libraries(jms_profile_test_${profile_build} PRIVATE shell32 ole32)
endforeach()
