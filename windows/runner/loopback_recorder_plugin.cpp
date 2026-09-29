#include "loopback_recorder_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "loopback_recorder.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using loopback::DefaultPath;
using loopback::Recorder;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return "";
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), size, nullptr, nullptr);
  return out;
}

class LoopbackRecorderPlugin {
 public:
  explicit LoopbackRecorderPlugin(flutter::PluginRegistrarWindows* registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/loopback_recorder",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
          Handle(call, std::move(result));
        });
    // Si se cierra la ventana grabando, se cierra bien el WAV (si no, queda
    // con el encabezado en cero).
    registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message == WM_CLOSE || message == WM_DESTROY) recorder_.Stop();
          return std::nullopt;
        });
  }

 private:
  EncodableMap Summary() {
    return EncodableMap{
        {EncodableValue("path"), EncodableValue(WideToUtf8(recorder_.path()))},
        {EncodableValue("durationMs"), EncodableValue(recorder_.duration_ms())},
        {EncodableValue("bytes"), EncodableValue(recorder_.bytes())},
    };
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args =
        call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const std::string& method = call.method_name();
    if (method == "start") {
      std::wstring path;
      if (args) {
        auto it = args->find(EncodableValue("path"));
        if (it != args->end()) {
          if (const auto* text = std::get_if<std::string>(&it->second)) path = Utf8ToWide(*text);
        }
      }
      std::wstring device;
      if (args) {
        auto it = args->find(EncodableValue("deviceId"));
        if (it != args->end()) {
          if (const auto* text = std::get_if<std::string>(&it->second)) device = Utf8ToWide(*text);
        }
      }
      if (path.empty()) path = DefaultPath();
      if (path.empty()) {
        result->Error("no_folder", "No se encontró la carpeta Música.");
        return;
      }
      const std::string error = recorder_.Start(path, device);
      if (!error.empty()) {
        result->Error("start_failed", error);
        return;
      }
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(WideToUtf8(path))},
          {EncodableValue("sampleRate"), EncodableValue(recorder_.sample_rate())},
          {EncodableValue("channels"), EncodableValue(recorder_.source_channels())},
      }));
    } else if (method == "stop") {
      recorder_.Stop();
      result->Success(EncodableValue(Summary()));
    } else if (method == "status") {
      EncodableMap status = Summary();
      status[EncodableValue("recording")] = EncodableValue(recorder_.running());
      status[EncodableValue("peak")] = EncodableValue(static_cast<double>(recorder_.TakePeak()));
      const std::string error = recorder_.error();
      status[EncodableValue("error")] = error.empty() ? EncodableValue() : EncodableValue(error);
      result->Success(EncodableValue(status));
    } else {
      result->NotImplemented();
    }
  }

  Recorder recorder_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
};

}  // namespace

void RegisterLoopbackRecorderPlugin(flutter::PluginRegistrarWindows* registrar) {
  static LoopbackRecorderPlugin* plugin = new LoopbackRecorderPlugin(registrar);
  (void)plugin;
}
