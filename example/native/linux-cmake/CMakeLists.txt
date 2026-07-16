cmake_minimum_required(VERSION 3.14)

project(desktop_updater_linux_consumer LANGUAGES CXX)

find_package(desktop_updater_native 2.7.0 EXACT CONFIG REQUIRED)
if(NOT DEFINED desktop_updater_native_HELPER_EXECUTABLE OR
   NOT EXISTS "${desktop_updater_native_HELPER_EXECUTABLE}")
  message(FATAL_ERROR "The installed helper metadata is unavailable")
endif()

add_executable(consumer main.cpp)
target_compile_features(consumer PRIVATE cxx_std_17)
target_link_libraries(consumer PRIVATE desktop_updater::native)
target_compile_definitions(consumer PRIVATE
  "DESKTOP_UPDATER_INSTALLED_HELPER_PATH=\"${desktop_updater_native_HELPER_EXECUTABLE}\"")
set_target_properties(consumer PROPERTIES OUTPUT_NAME linux_installed_consumer)
install(TARGETS consumer RUNTIME DESTINATION bin)

enable_testing()
set(DESKTOP_UPDATER_LINUX_CONSUMER_STAGE "" CACHE PATH
  "Prepared signed stage for the installed helper exchange")
if(DESKTOP_UPDATER_LINUX_CONSUMER_STAGE)
  add_test(NAME desktop_updater_linux_installed_consumer
    COMMAND
      "${CMAKE_INSTALL_PREFIX}/bin/linux_installed_consumer"
      --exchange "${DESKTOP_UPDATER_LINUX_CONSUMER_STAGE}")
else()
  add_test(NAME desktop_updater_linux_installed_consumer COMMAND consumer)
endif()
