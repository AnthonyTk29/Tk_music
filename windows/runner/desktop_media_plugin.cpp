#include <windows.h>
#include <objidl.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <initguid.h>
#include <propkey.h>

#include "desktop_media_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_file_tools.h"
#include "ui_task_runner.h"

using Microsoft::WRL::ComPtr;

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = std::unique_ptr<flutter::MethodResult<EncodableValue>>;
using SharedResult = std::shared_ptr<Result>;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

std::string WideToUtf8(const wchar_t* wide) {
  if (!wide || !*wide) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return "";
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), size, nullptr, nullptr);
  return out;
}

// Un hilo de trabajo con COM de apartamento (lo que pide el Shell) y una
// cola: las carátulas se piden de a muchas al scrollear una lista, y un
// hilo por pedido saturaba el equipo.
class Worker {
 public:
  Worker() : thread_([this]() { Run(); }) {}

  void Post(std::function<void()> task) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      tasks_.push_back(std::move(task));
    }
    ready_.notify_one();
  }

 private:
  void Run() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    for (;;) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this]() { return !tasks_.empty(); });
        task = std::move(tasks_.front());
        tasks_.pop_front();
      }
      task();
    }
  }

  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<std::function<void()>> tasks_;
  std::thread thread_;
};

std::string ReadString(IPropertyStore* store, const PROPERTYKEY& key) {
  PROPVARIANT value;
  PropVariantInit(&value);
  std::string out;
  if (SUCCEEDED(store->GetValue(key, &value)) && value.vt != VT_EMPTY) {
    // Para listas (varios artistas/géneros) une los valores con "; ".
    PWSTR text = nullptr;
    if (SUCCEEDED(PropVariantToStringAlloc(value, &text)) && text) {
      out = WideToUtf8(text);
      CoTaskMemFree(text);
    }
  }
  PropVariantClear(&value);
  return out;
}

EncodableValue ReadTags(const std::string& path) {
  EncodableMap tags;
  ComPtr<IPropertyStore> store;
  const std::wstring wide = Utf8ToWide(path);
  if (wide.empty() ||
      FAILED(SHGetPropertyStoreFromParsingName(wide.c_str(), nullptr, GPS_DEFAULT,
                                               IID_PPV_ARGS(&store)))) {
    return EncodableValue(tags);
  }
  auto put = [&tags](const char* key, const std::string& value) {
    if (!value.empty()) tags[EncodableValue(key)] = EncodableValue(value);
  };
  put("title", ReadString(store.Get(), PKEY_Title));
  put("artist", ReadString(store.Get(), PKEY_Music_Artist));
  put("album", ReadString(store.Get(), PKEY_Music_AlbumTitle));
  put("genre", ReadString(store.Get(), PKEY_Music_Genre));

  PROPVARIANT duration;
  PropVariantInit(&duration);
  ULONGLONG ticks = 0;
  if (SUCCEEDED(store->GetValue(PKEY_Media_Duration, &duration)) &&
      SUCCEEDED(PropVariantToUInt64(duration, &ticks)) && ticks > 0) {
    tags[EncodableValue("durationMs")] = EncodableValue(static_cast<int64_t>(ticks / 10000));
  }
  PropVariantClear(&duration);
  return EncodableValue(tags);
}

// Calidad del audio (gestor de archivos del Modo DJ), ver audio_file_tools.h.
EncodableValue ReadAudioInfo(const std::string& path) {
  const auto info = audio_file_tools::ReadAudioFileInfo(Utf8ToWide(path));
  EncodableMap map;
  auto put = [&map](const char* key, uint32_t value) {
    if (value > 0) map[EncodableValue(key)] = EncodableValue(static_cast<int32_t>(value));
  };
  put("bitrate", info.bitrate);
  put("sampleRate", info.sample_rate);
  put("channels", info.channels);
  put("bitsPerSample", info.bits_per_sample);
  if (info.duration_ms > 0) {
    map[EncodableValue("durationMs")] = EncodableValue(static_cast<int64_t>(info.duration_ms));
  }
  if (info.has_vbr) map[EncodableValue("vbr")] = EncodableValue(info.vbr);
  return EncodableValue(map);
}

bool MoveToRecycleBin(const std::string& path) {
  return audio_file_tools::MoveToRecycleBin(Utf8ToWide(path));
}

// Carátula embebida → JPEG. Sin carátula (SIIGBF_THUMBNAILONLY falla) → vacío.
std::vector<uint8_t> ReadArtwork(const std::string& path, int size) {
  std::vector<uint8_t> bytes;
  const std::wstring wide = Utf8ToWide(path);
  ComPtr<IShellItemImageFactory> factory;
  if (wide.empty() ||
      FAILED(SHCreateItemFromParsingName(wide.c_str(), nullptr, IID_PPV_ARGS(&factory)))) {
    return bytes;
  }
  HBITMAP bitmap = nullptr;
  if (FAILED(factory->GetImage(SIZE{size, size}, SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK,
                               &bitmap)) ||
      !bitmap) {
    return bytes;
  }

  ComPtr<IWICImagingFactory> wic;
  ComPtr<IWICBitmap> source;
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  UINT width = 0;
  UINT height = 0;
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  const bool ok =
      SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_PPV_ARGS(&wic))) &&
      SUCCEEDED(wic->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source)) &&
      SUCCEEDED(source->GetSize(&width, &height)) &&
      SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) &&
      SUCCEEDED(wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder)) &&
      SUCCEEDED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) &&
      SUCCEEDED(encoder->CreateNewFrame(&frame, nullptr)) &&
      SUCCEEDED(frame->Initialize(nullptr)) && SUCCEEDED(frame->SetSize(width, height)) &&
      SUCCEEDED(frame->SetPixelFormat(&format)) &&
      SUCCEEDED(frame->WriteSource(source.Get(), nullptr)) && SUCCEEDED(frame->Commit()) &&
      SUCCEEDED(encoder->Commit());
  DeleteObject(bitmap);
  if (!ok) return bytes;

  HGLOBAL global = nullptr;
  if (FAILED(GetHGlobalFromStream(stream.Get(), &global)) || !global) return bytes;
  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return bytes;
  const size_t length = static_cast<size_t>(stat.cbSize.QuadPart);
  const void* data = GlobalLock(global);
  if (data) {
    bytes.resize(length);
    std::memcpy(bytes.data(), data, length);
    GlobalUnlock(global);
  }
  return bytes;
}

class DesktopMediaPlugin {
 public:
  explicit DesktopMediaPlugin(flutter::PluginRegistrarWindows* registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/desktop_media",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
          Handle(call, std::move(result));
        });
  }

 private:
  void Handle(const flutter::MethodCall<EncodableValue>& call, Result result) {
    static const EncodableMap kEmpty;
    const auto* maybe_args =
        call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    const EncodableMap& args = maybe_args ? *maybe_args : kEmpty;
    auto shared = std::make_shared<Result>(std::move(result));

    if (call.method_name() == "readTags") {
      std::vector<std::string> paths;
      auto it = args.find(EncodableValue("paths"));
      if (it != args.end()) {
        if (const auto* list = std::get_if<EncodableList>(&it->second)) {
          for (const auto& item : *list) {
            if (const auto* text = std::get_if<std::string>(&item)) paths.push_back(*text);
          }
        }
      }
      tags_worker_.Post([this, paths, shared]() {
        EncodableList out;
        out.reserve(paths.size());
        for (const auto& path : paths) out.push_back(ReadTags(path));
        ui_.Post([shared, out = std::move(out)]() { (*shared)->Success(EncodableValue(out)); });
      });
    } else if (call.method_name() == "artwork") {
      std::string path;
      int size = 300;
      if (auto it = args.find(EncodableValue("path")); it != args.end()) {
        if (const auto* text = std::get_if<std::string>(&it->second)) path = *text;
      }
      if (auto it = args.find(EncodableValue("size")); it != args.end()) {
        if (const auto* value = std::get_if<int32_t>(&it->second)) size = *value;
      }
      artwork_worker_.Post([this, path, size, shared]() {
        std::vector<uint8_t> bytes = ReadArtwork(path, size);
        ui_.Post([shared, bytes = std::move(bytes)]() {
          if (bytes.empty()) {
            (*shared)->Success();
          } else {
            (*shared)->Success(EncodableValue(bytes));
          }
        });
      });
    } else if (call.method_name() == "audioInfo" || call.method_name() == "recycle") {
      std::vector<std::string> paths;
      auto it = args.find(EncodableValue("paths"));
      if (it != args.end()) {
        if (const auto* list = std::get_if<EncodableList>(&it->second)) {
          for (const auto& item : *list) {
            if (const auto* text = std::get_if<std::string>(&item)) paths.push_back(*text);
          }
        }
      }
      const bool recycle = call.method_name() == "recycle";
      tags_worker_.Post([this, paths, recycle, shared]() {
        EncodableList out;
        out.reserve(paths.size());
        for (const auto& path : paths) {
          out.push_back(recycle ? EncodableValue(MoveToRecycleBin(path)) : ReadAudioInfo(path));
        }
        ui_.Post([shared, out = std::move(out)]() { (*shared)->Success(EncodableValue(out)); });
      });
    } else {
      (*shared)->NotImplemented();
    }
  }

  UiTaskRunner ui_;
  Worker tags_worker_;
  Worker artwork_worker_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
};

}  // namespace

void RegisterDesktopMediaPlugin(flutter::PluginRegistrarWindows* registrar) {
  static DesktopMediaPlugin* plugin = new DesktopMediaPlugin(registrar);
  (void)plugin;
}
