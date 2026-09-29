#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "audio_analysis_plugin.h"
#include "bluetooth_sync_plugin.h"
#include "desktop_media_plugin.h"
#include "loopback_recorder_plugin.h"
#include "midi_plugin.h"
#include "media_controls_plugin.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Plugins propios de la app (sin pasar por pub.dev), con el mismo patrón
  // que los generados arriba:
  //  - "Sincronizar con otro dispositivo": Bluetooth Classic (RFCOMM).
  //  - Onda/espectro/volumen: decodificación con Media Foundation.
  //  - Tags y carátulas de la biblioteca: sistema de propiedades de Windows.
  //  - Controles multimedia del sistema (SMTC) y teclas multimedia.
  //  - "Grabar mezcla" del Modo DJ: captura de la salida de audio.
  //  - Controladores DJ por MIDI (Numark Mixtrack Pro 3…).
  auto registrar_for = [this](const char* name) {
    return flutter::PluginRegistrarManager::GetInstance()
        ->GetRegistrar<flutter::PluginRegistrarWindows>(
            flutter_controller_->engine()->GetRegistrarForPlugin(name));
  };
  BluetoothSyncPlugin::RegisterWithRegistrar(registrar_for("BluetoothSyncPlugin"));
  RegisterAudioAnalysisPlugin(registrar_for("AudioAnalysisPlugin"));
  RegisterDesktopMediaPlugin(registrar_for("DesktopMediaPlugin"));
  RegisterMediaControlsPlugin(registrar_for("MediaControlsPlugin"), GetHandle());
  RegisterLoopbackRecorderPlugin(registrar_for("LoopbackRecorderPlugin"));
  RegisterMidiPlugin(registrar_for("MidiPlugin"));

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
