#include <windows.h>
#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include "media_controls_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "ui_task_runner.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;
namespace WF = ABI::Windows::Foundation;
namespace WM = ABI::Windows::Media;

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = std::unique_ptr<flutter::MethodResult<EncodableValue>>;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

std::string GetString(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return "";
  if (const auto* text = std::get_if<std::string>(&it->second)) return *text;
  return "";
}

int64_t GetInt(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return 0;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  return 0;
}

bool GetBool(const EncodableMap& args, const char* key, bool fallback) {
  auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return fallback;
}

class MediaControlsPlugin {
 public:
  MediaControlsPlugin(flutter::PluginRegistrarWindows* registrar, HWND window) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/media_controls", &codec);
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
          Handle(call, std::move(result));
        });

    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/media_controls/events", &codec);
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

    ready_ = Initialize(window);
  }

 private:
  bool Initialize(HWND window) {
    ComPtr<ISystemMediaTransportControlsInterop> interop;
    if (FAILED(RoGetActivationFactory(
            HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControls).Get(),
            IID_PPV_ARGS(&interop))) ||
        FAILED(interop->GetForWindow(window, IID_PPV_ARGS(&controls_)))) {
      return false;
    }
    controls_->put_IsPlayEnabled(true);
    controls_->put_IsPauseEnabled(true);
    controls_->put_IsStopEnabled(true);
    controls_->put_IsNextEnabled(true);
    controls_->put_IsPreviousEnabled(true);
    controls_->put_IsEnabled(false);  // hasta que suene algo

    auto handler = Callback<WF::ITypedEventHandler<WM::SystemMediaTransportControls*,
                                                   WM::SystemMediaTransportControlsButtonPressedEventArgs*>>(
        [this](WM::ISystemMediaTransportControls*,
               WM::ISystemMediaTransportControlsButtonPressedEventArgs* args) -> HRESULT {
          WM::SystemMediaTransportControlsButton button;
          if (FAILED(args->get_Button(&button))) return S_OK;
          const char* name = nullptr;
          switch (button) {
            case WM::SystemMediaTransportControlsButton_Play: name = "play"; break;
            case WM::SystemMediaTransportControlsButton_Pause: name = "pause"; break;
            case WM::SystemMediaTransportControlsButton_Stop: name = "stop"; break;
            case WM::SystemMediaTransportControlsButton_Next: name = "next"; break;
            case WM::SystemMediaTransportControlsButton_Previous: name = "previous"; break;
            default: return S_OK;
          }
          // Llega en un hilo del sistema: el EventSink se usa en el de la UI.
          ui_.Post([this, button_name = std::string(name)]() {
            if (!sink_) return;
            EncodableMap event;
            event[EncodableValue("button")] = EncodableValue(button_name);
            sink_->Success(EncodableValue(event));
          });
          return S_OK;
        });
    controls_->add_ButtonPressed(handler.Get(), &button_token_);

    controls_->get_DisplayUpdater(&display_);
    if (display_) display_->put_Type(WM::MediaPlaybackType_Music);
    return true;
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call, Result result) {
    if (!ready_) {
      // Sin SMTC (Windows muy viejo o sesión sin shell): no es un error de
      // la app, simplemente no hay controles del sistema.
      result->Success();
      return;
    }
    if (call.method_name() == "clear") {
      controls_->put_PlaybackStatus(WM::MediaPlaybackStatus_Closed);
      controls_->put_IsEnabled(false);
      if (display_) {
        display_->ClearAll();
        display_->put_Type(WM::MediaPlaybackType_Music);
      }
      result->Success();
      return;
    }
    if (call.method_name() != "update") {
      result->NotImplemented();
      return;
    }
    static const EncodableMap kEmpty;
    const auto* maybe_args =
        call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const EncodableMap& args = maybe_args ? *maybe_args : kEmpty;

    controls_->put_IsEnabled(true);
    controls_->put_IsNextEnabled(GetBool(args, "canNext", true));
    controls_->put_IsPreviousEnabled(GetBool(args, "canPrevious", true));
    controls_->put_PlaybackStatus(GetBool(args, "playing", false)
                                      ? WM::MediaPlaybackStatus_Playing
                                      : WM::MediaPlaybackStatus_Paused);

    const std::wstring title = Utf8ToWide(GetString(args, "title"));
    const std::wstring artist = Utf8ToWide(GetString(args, "artist"));
    const std::wstring album = Utf8ToWide(GetString(args, "album"));
    if (display_) {
      ComPtr<WM::IMusicDisplayProperties> music;
      if (SUCCEEDED(display_->get_MusicProperties(&music))) {
        music->put_Title(HStringReference(title.c_str()).Get());
        music->put_Artist(HStringReference(artist.c_str()).Get());
        ComPtr<WM::IMusicDisplayProperties2> music2;
        if (SUCCEEDED(music.As(&music2))) {
          music2->put_AlbumTitle(HStringReference(album.c_str()).Get());
        }
      }
      display_->Update();
    }
    UpdateTimeline(GetInt(args, "positionMs"), GetInt(args, "durationMs"));
    result->Success();
  }

  void UpdateTimeline(int64_t position_ms, int64_t duration_ms) {
    ComPtr<WM::ISystemMediaTransportControls2> controls2;
    if (duration_ms <= 0 || FAILED(controls_.As(&controls2))) return;
    ComPtr<IInspectable> instance;
    if (FAILED(RoActivateInstance(
            HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties)
                .Get(),
            &instance))) {
      return;
    }
    ComPtr<WM::ISystemMediaTransportControlsTimelineProperties> timeline;
    if (FAILED(instance.As(&timeline))) return;
    // TimeSpan va en unidades de 100ns.
    timeline->put_StartTime(WF::TimeSpan{0});
    timeline->put_MinSeekTime(WF::TimeSpan{0});
    timeline->put_EndTime(WF::TimeSpan{duration_ms * 10000});
    timeline->put_MaxSeekTime(WF::TimeSpan{duration_ms * 10000});
    timeline->put_Position(WF::TimeSpan{position_ms * 10000});
    controls2->UpdateTimelineProperties(timeline.Get());
  }

  UiTaskRunner ui_;
  bool ready_ = false;
  ComPtr<WM::ISystemMediaTransportControls> controls_;
  ComPtr<WM::ISystemMediaTransportControlsDisplayUpdater> display_;
  EventRegistrationToken button_token_ = {};
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;
};

}  // namespace

void RegisterMediaControlsPlugin(flutter::PluginRegistrarWindows* registrar, HWND window) {
  static MediaControlsPlugin* plugin = new MediaControlsPlugin(registrar, window);
  (void)plugin;
}
