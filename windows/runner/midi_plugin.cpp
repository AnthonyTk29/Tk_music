#include "midi_plugin.h"

#include <windows.h>
#include <mmsystem.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "ui_task_runner.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::string WideToUtf8(const wchar_t* wide) {
  if (!wide || !*wide) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return "";
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), size, nullptr, nullptr);
  return out;
}

std::vector<std::string> InputNames() {
  std::vector<std::string> names;
  const UINT count = midiInGetNumDevs();
  for (UINT i = 0; i < count; i++) {
    MIDIINCAPSW caps{};
    if (midiInGetDevCapsW(i, &caps, sizeof(caps)) == MMSYSERR_NOERROR) {
      names.push_back(WideToUtf8(caps.szPname));
    } else {
      names.push_back("");
    }
  }
  return names;
}

std::vector<std::string> OutputNames() {
  std::vector<std::string> names;
  const UINT count = midiOutGetNumDevs();
  for (UINT i = 0; i < count; i++) {
    MIDIOUTCAPSW caps{};
    if (midiOutGetDevCapsW(i, &caps, sizeof(caps)) == MMSYSERR_NOERROR) {
      names.push_back(WideToUtf8(caps.szPname));
    } else {
      names.push_back("");
    }
  }
  return names;
}

int IndexOf(const std::vector<std::string>& names, const std::string& name) {
  for (size_t i = 0; i < names.size(); i++) {
    if (names[i] == name) return static_cast<int>(i);
  }
  return -1;
}

class MidiPlugin {
 public:
  explicit MidiPlugin(flutter::PluginRegistrarWindows* registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/midi", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
          Handle(call, std::move(result));
        });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/midi/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
        [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          sink_ = std::move(sink);
          return nullptr;
        },
        [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          sink_.reset();
          return nullptr;
        }));
    // Al cerrar la app, las luces del controlador se apagan desde Dart;
    // acá solo se liberan los puertos.
    registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message == WM_DESTROY) Close();
          return std::nullopt;
        });
  }

 private:
  // Lo llama el driver MIDI desde su propio hilo: solo encola.
  static void CALLBACK OnInput(HMIDIIN, UINT message, DWORD_PTR instance, DWORD_PTR param1,
                               DWORD_PTR) {
    if (message != MIM_DATA) return;
    auto* self = reinterpret_cast<MidiPlugin*>(instance);
    const auto packed = static_cast<DWORD>(param1);
    const uint8_t status = packed & 0xFF;
    // Mensajes de reloj/estado (0xF8…) no sirven acá.
    if (status >= 0xF0) return;
    bool post = false;
    {
      std::lock_guard<std::mutex> lock(self->mutex_);
      self->pending_.push_back(status);
      self->pending_.push_back((packed >> 8) & 0x7F);
      self->pending_.push_back((packed >> 16) & 0x7F);
      if (!self->posted_) {
        self->posted_ = true;
        post = true;
      }
    }
    if (post) self->ui_.Post([self]() { self->Flush(); });
  }

  void Flush() {
    std::vector<uint8_t> batch;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      batch.swap(pending_);
      posted_ = false;
    }
    if (!sink_ || batch.empty()) return;
    EncodableList list;
    list.reserve(batch.size());
    for (uint8_t b : batch) list.push_back(EncodableValue(static_cast<int32_t>(b)));
    sink_->Success(EncodableValue(list));
  }

  void Close() {
    if (in_) {
      midiInStop(in_);
      midiInReset(in_);
      midiInClose(in_);
      in_ = nullptr;
    }
    if (out_) {
      midiOutReset(out_);
      midiOutClose(out_);
      out_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.clear();
  }

  static std::string ArgString(const EncodableMap* args, const char* key) {
    if (!args) return "";
    auto it = args->find(EncodableValue(key));
    if (it == args->end()) return "";
    const auto* text = std::get_if<std::string>(&it->second);
    return text ? *text : "";
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const std::string& method = call.method_name();
    if (method == "devices") {
      EncodableList inputs, outputs;
      for (const auto& name : InputNames()) inputs.push_back(EncodableValue(name));
      for (const auto& name : OutputNames()) outputs.push_back(EncodableValue(name));
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("inputs"), EncodableValue(inputs)},
          {EncodableValue("outputs"), EncodableValue(outputs)},
      }));
    } else if (method == "open") {
      Close();
      const int in_index = IndexOf(InputNames(), ArgString(args, "input"));
      if (in_index < 0) {
        result->Error("not_found", "No se encontró el controlador.");
        return;
      }
      if (midiInOpen(&in_, static_cast<UINT>(in_index), reinterpret_cast<DWORD_PTR>(&OnInput),
                     reinterpret_cast<DWORD_PTR>(this), CALLBACK_FUNCTION) != MMSYSERR_NOERROR) {
        in_ = nullptr;
        result->Error("busy",
                      "No se pudo abrir el controlador: puede que otro programa (VirtualDJ, "
                      "Serato…) lo esté usando. Cerralo y volvé a intentar.");
        return;
      }
      midiInStart(in_);
      // Sin salida se usa igual, pero sin luces.
      const int out_index = IndexOf(OutputNames(), ArgString(args, "output"));
      if (out_index >= 0 &&
          midiOutOpen(&out_, static_cast<UINT>(out_index), 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) {
        out_ = nullptr;
      }
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("lights"), EncodableValue(out_ != nullptr)},
      }));
    } else if (method == "send") {
      if (out_ && args) {
        auto it = args->find(EncodableValue("bytes"));
        if (it != args->end()) {
          std::vector<int32_t> bytes;
          if (const auto* list = std::get_if<EncodableList>(&it->second)) {
            for (const auto& item : *list) {
              if (const auto* value = std::get_if<int32_t>(&item)) bytes.push_back(*value);
            }
          } else if (const auto* typed = std::get_if<std::vector<int32_t>>(&it->second)) {
            bytes = *typed;
          } else if (const auto* raw = std::get_if<std::vector<uint8_t>>(&it->second)) {
            bytes.assign(raw->begin(), raw->end());
          }
          // De a mensajes de 3 bytes.
          for (size_t i = 0; i + 2 < bytes.size(); i += 3) {
            const DWORD message = (bytes[i] & 0xFF) | ((bytes[i + 1] & 0x7F) << 8) |
                                  ((bytes[i + 2] & 0x7F) << 16);
            midiOutShortMsg(out_, message);
          }
        }
      }
      result->Success();
    } else if (method == "close") {
      Close();
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  UiTaskRunner ui_;
  std::mutex mutex_;
  std::vector<uint8_t> pending_;
  bool posted_ = false;
  HMIDIIN in_ = nullptr;
  HMIDIOUT out_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
};

}  // namespace

void RegisterMidiPlugin(flutter::PluginRegistrarWindows* registrar) {
  static MidiPlugin* plugin = new MidiPlugin(registrar);
  (void)plugin;
}
