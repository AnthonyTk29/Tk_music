cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "bluetooth_sync_plugin.cpp"
  "audio_analysis_plugin.cpp"
  "desktop_media_plugin.cpp"
  "media_controls_plugin.cpp"
  "loopback_recorder_plugin.cpp"
  "midi_plugin.cpp"
  "ui_task_runner.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# Para bluetooth_sync_plugin.cpp ("Sincronizar con otro dispositivo"): sockets
# Winsock (Ws2_32) y las APIs de Bluetooth clásico de Windows (Bthprops).
target_link_libraries(${BINARY_NAME} PRIVATE "Ws2_32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "Bthprops.lib")
# audio_analysis_plugin.cpp: decodificación de audio con Media Foundation.
target_link_libraries(${BINARY_NAME} PRIVATE "mfplat.lib" "mfreadwrite.lib" "mfuuid.lib")
# desktop_media_plugin.cpp: tags (sistema de propiedades) y carátulas (Shell
# + WIC para codificarlas a JPEG).
target_link_libraries(${BINARY_NAME} PRIVATE "propsys.lib" "shell32.lib" "windowscodecs.lib" "ole32.lib")
# media_controls_plugin.cpp: controles multimedia del sistema (WinRT/SMTC).
target_link_libraries(${BINARY_NAME} PRIVATE "runtimeobject.lib")
# loopback_recorder_plugin.cpp: "Grabar mezcla" (captura loopback de WASAPI;
# ole32 y shell32 ya están arriba).
# midi_plugin.cpp: controladores DJ por MIDI (WinMM).
target_link_libraries(${BINARY_NAME} PRIVATE "winmm.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
