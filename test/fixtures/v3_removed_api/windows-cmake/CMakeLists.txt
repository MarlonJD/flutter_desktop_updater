cmake_minimum_required(VERSION 3.22)
project(desktop_updater_v3_removed_api_windows LANGUAGES C CXX)

if(NOT DEFINED DESKTOP_UPDATER_SOURCE_ROOT)
  message(FATAL_ERROR "DESKTOP_UPDATER_SOURCE_ROOT is required")
endif()

function(expect_legacy_consumer_rejected target expected_symbol)
  try_compile(
    compiled
    "${CMAKE_BINARY_DIR}/${target}"
    "${CMAKE_CURRENT_LIST_DIR}/consumer"
    desktop_updater_v3_removed_api_windows_consumer
    "${target}"
    CMAKE_FLAGS
      "-DDESKTOP_UPDATER_SOURCE_ROOT:PATH=${DESKTOP_UPDATER_SOURCE_ROOT}"
    OUTPUT_VARIABLE compiler_output
  )
  set(failures ${legacy_consumer_failures})
  if(compiled)
    list(APPEND failures
      "Legacy ${target} consumer unexpectedly compiled: ${expected_symbol}"
    )
  elseif(NOT compiler_output MATCHES "${expected_symbol}")
    list(APPEND failures
      "Legacy ${target} consumer failed without the intended ${expected_symbol} diagnostic:\n${compiler_output}"
    )
  endif()
  set(legacy_consumer_failures "${failures}" PARENT_SCOPE)
endfunction()

expect_legacy_consumer_rejected(
  legacy_windows_c
  desktop_updater_schedule_install_and_relaunch_v1
)
expect_legacy_consumer_rejected(
  legacy_windows_cpp
  desktop_updater_schedule_install_and_relaunch_v1
)

if(legacy_consumer_failures)
  string(JOIN "\n" failure_report ${legacy_consumer_failures})
  message(FATAL_ERROR "${failure_report}")
endif()
