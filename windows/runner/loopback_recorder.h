#ifndef RUNNER_LOOPBACK_RECORDER_H_
#define RUNNER_LOOPBACK_RECORDER_H_

// Captura "loopback" de WASAPI: graba lo que sale por la salida de audio
// predeterminada de Windows a un WAV estéreo de 16 bits. Sin nada de
// Flutter, para poder probarlo solo (ver test/native/loopback_recorder_test.cpp).
// Lo usa loopback_recorder_plugin.cpp ("Grabar mezcla" del Modo DJ).

#include <windows.h>
#include <audioclient.h>
#include <knownfolders.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace loopback {

using Microsoft::WRL::ComPtr;

// Música\TK Music\Mezclas\Mezcla AAAA-MM-DD HH.MM.SS.wav (la carpeta Música
// real del usuario, aunque esté redirigida a OneDrive).
inline std::wstring DefaultPath() {
  PWSTR music = nullptr;
  std::wstring folder;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Music, 0, nullptr, &music)) && music) {
    folder = music;
  }
  CoTaskMemFree(music);
  if (folder.empty()) return L"";
  folder += L"\\TK Music";
  CreateDirectoryW(folder.c_str(), nullptr);
  folder += L"\\Mezclas";
  CreateDirectoryW(folder.c_str(), nullptr);
  SYSTEMTIME now;
  GetLocalTime(&now);
  wchar_t name[80];
  swprintf_s(name, L"\\Mezcla %04u-%02u-%02u %02u.%02u.%02u.wav", now.wYear, now.wMonth,
             now.wDay, now.wHour, now.wMinute, now.wSecond);
  return folder + name;
}

inline void WriteWavHeader(FILE* file, uint32_t sample_rate, uint32_t data_bytes) {
  auto u16 = [file](uint16_t v) { fwrite(&v, sizeof(v), 1, file); };
  auto u32 = [file](uint32_t v) { fwrite(&v, sizeof(v), 1, file); };
  fseek(file, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, file);
  u32(36 + data_bytes);
  fwrite("WAVE", 1, 4, file);
  fwrite("fmt ", 1, 4, file);
  u32(16);
  u16(1);  // PCM
  u16(2);  // estéreo
  u32(sample_rate);
  u32(sample_rate * 4);
  u16(4);
  u16(16);
  fwrite("data", 1, 4, file);
  u32(data_bytes);
}

// La salida activa cuyo id de Windows termina en [suffix]
// ("{0.0.0.00000000}.{guid}" termina en "{guid}").
inline HRESULT FindBySuffix(IMMDeviceEnumerator* enumerator, const std::wstring& suffix,
                            IMMDevice** out) {
  ComPtr<IMMDeviceCollection> collection;
  HRESULT hr = enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &collection);
  if (FAILED(hr)) return hr;
  UINT count = 0;
  collection->GetCount(&count);
  for (UINT i = 0; i < count; i++) {
    ComPtr<IMMDevice> device;
    if (FAILED(collection->Item(i, &device))) continue;
    LPWSTR id = nullptr;
    if (FAILED(device->GetId(&id)) || !id) continue;
    const std::wstring text(id);
    CoTaskMemFree(id);
    if (text.size() >= suffix.size() &&
        _wcsicmp(text.c_str() + text.size() - suffix.size(), suffix.c_str()) == 0) {
      *out = device.Detach();
      return S_OK;
    }
  }
  return E_NOTFOUND;
}

enum class SampleKind { kUnknown, kFloat32, kInt16, kInt24, kInt32 };

// Captura "loopback" de la salida predeterminada en un hilo propio.
class Recorder {
 public:
  ~Recorder() { Stop(); }

  // Arranca y espera a que la captura esté andando. Devuelve "" si salió
  // bien o el motivo del error.
  // [device_id]: la salida a grabar (id de Windows, el de mpv sin
  // "wasapi/"); vacío = la predeterminada.
  std::string Start(const std::wstring& path, const std::wstring& device_id = L"") {
    Stop();
    device_id_ = device_id;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      error_.clear();
      startup_done_ = false;
      startup_error_.clear();
    }
    path_ = path;
    frames_ = 0;
    peak_ = 0;
    stop_ = false;
    thread_ = std::thread([this]() { Run(); });
    std::unique_lock<std::mutex> lock(mutex_);
    ready_.wait(lock, [this]() { return startup_done_; });
    if (!startup_error_.empty()) {
      lock.unlock();
      if (thread_.joinable()) thread_.join();
      return startup_error_;
    }
    return "";
  }

  void Stop() {
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    running_ = false;
  }

  bool running() const { return running_; }
  int sample_rate() const { return sample_rate_; }
  int source_channels() const { return source_channels_; }
  const std::wstring& path() const { return path_; }
  int64_t duration_ms() const {
    const int rate = sample_rate_;
    return rate > 0 ? frames_.load() * 1000 / rate : 0;
  }
  int64_t bytes() const { return 44 + frames_.load() * 4; }
  float TakePeak() { return peak_.exchange(0.0f); }
  std::string error() {
    std::lock_guard<std::mutex> lock(mutex_);
    return error_;
  }

 private:
  void FinishStartup(const std::string& error) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      startup_done_ = true;
      startup_error_ = error;
    }
    ready_.notify_all();
  }

  void Run() {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    RunCapture();
    running_ = false;
    if (SUCCEEDED(co)) CoUninitialize();
  }

  void RunCapture() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> capture_client;
    ComPtr<IAudioCaptureClient> capture;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&enumerator));
    if (SUCCEEDED(hr)) {
      if (device_id_.empty()) {
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
      } else {
        hr = enumerator->GetDevice(device_id_.c_str(), &device);
        // mpv nombra las salidas solo con el final del id ("{guid}").
        if (FAILED(hr)) hr = FindBySuffix(enumerator.Get(), device_id_, &device);
      }
    }
    if (FAILED(hr)) {
      FinishStartup(device_id_.empty() ? "No hay una salida de audio activa en Windows."
                                       : "No se encontró la salida de audio elegida.");
      return;
    }
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(capture_client.GetAddressOf()));
    WAVEFORMATEX* format = nullptr;
    if (SUCCEEDED(hr)) hr = capture_client->GetMixFormat(&format);
    if (FAILED(hr) || !format) {
      FinishStartup("No se pudo abrir la salida de audio para grabarla.");
      return;
    }
    std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> format_owner(format, CoTaskMemFree);

    WORD tag = format->wFormatTag;
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
      const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
      if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
        tag = WAVE_FORMAT_IEEE_FLOAT;
      } else if (IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) {
        tag = WAVE_FORMAT_PCM;
      }
    }
    const int channels = format->nChannels;
    const int bytes_per_sample = channels > 0 ? format->nBlockAlign / channels : 0;
    SampleKind kind = SampleKind::kUnknown;
    if (tag == WAVE_FORMAT_IEEE_FLOAT && bytes_per_sample == 4) {
      kind = SampleKind::kFloat32;
    } else if (tag == WAVE_FORMAT_PCM) {
      if (bytes_per_sample == 2) kind = SampleKind::kInt16;
      if (bytes_per_sample == 3) kind = SampleKind::kInt24;
      if (bytes_per_sample == 4) kind = SampleKind::kInt32;
    }
    if (kind == SampleKind::kUnknown || channels < 1) {
      FinishStartup("El formato de la salida de audio no es compatible con la grabación.");
      return;
    }

    // Búfer de 1 s: se vacía cada ~10 ms.
    const REFERENCE_TIME buffer = 10000000;
    hr = capture_client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                    buffer, 0, format, nullptr);
    if (SUCCEEDED(hr)) hr = capture_client->GetService(IID_PPV_ARGS(&capture));
    if (FAILED(hr)) {
      FinishStartup("Windows no dejó grabar la salida de audio.");
      return;
    }

    // Con la salida en silencio, la captura loopback no entrega paquetes y
    // la grabación quedaría "comprimida" (sin las pausas). Un flujo que
    // reproduce silencio en la misma salida la mantiene andando; no se
    // escucha nada. Si falla, se graba igual.
    ComPtr<IAudioClient> silence_client;
    ComPtr<IAudioRenderClient> silence;
    UINT32 silence_frames = 0;
    if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                   reinterpret_cast<void**>(silence_client.GetAddressOf()))) &&
        SUCCEEDED(silence_client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, buffer, 0, format,
                                             nullptr)) &&
        SUCCEEDED(silence_client->GetBufferSize(&silence_frames)) &&
        SUCCEEDED(silence_client->GetService(IID_PPV_ARGS(&silence)))) {
      BYTE* data = nullptr;
      if (SUCCEEDED(silence->GetBuffer(silence_frames, &data))) {
        silence->ReleaseBuffer(silence_frames, AUDCLNT_BUFFERFLAGS_SILENT);
      }
      silence_client->Start();
    } else {
      silence.Reset();
      silence_client.Reset();
    }

    FILE* file = nullptr;
    if (_wfopen_s(&file, path_.c_str(), L"wb") != 0 || !file) {
      if (silence_client) silence_client->Stop();
      FinishStartup("No se pudo crear el archivo de la grabación.");
      return;
    }
    sample_rate_ = static_cast<int>(format->nSamplesPerSec);
    source_channels_ = channels;
    WriteWavHeader(file, format->nSamplesPerSec, 0);

    hr = capture_client->Start();
    if (FAILED(hr)) {
      fclose(file);
      DeleteFileW(path_.c_str());
      if (silence_client) silence_client->Stop();
      FinishStartup("Windows no dejó grabar la salida de audio.");
      return;
    }
    running_ = true;
    FinishStartup("");

    auto read = [kind](const BYTE* p) -> float {
      switch (kind) {
        case SampleKind::kFloat32: {
          float v;
          std::memcpy(&v, p, 4);
          return v;
        }
        case SampleKind::kInt16: {
          int16_t v;
          std::memcpy(&v, p, 2);
          return v / 32768.0f;
        }
        case SampleKind::kInt24: {
          int32_t v = p[0] | (p[1] << 8) | (p[2] << 16);
          if (v & 0x800000) v |= ~0xFFFFFF;
          return v / 8388608.0f;
        }
        case SampleKind::kInt32: {
          int32_t v;
          std::memcpy(&v, p, 4);
          return v / 2147483648.0f;
        }
        default:
          return 0.0f;
      }
    };
    auto to16 = [](float v) -> int16_t {
      const float scaled = std::round(v * 32767.0f);
      return static_cast<int16_t>(std::clamp(scaled, -32768.0f, 32767.0f));
    };

    // Un WAV no puede pasar de 4 GB (~6 h a 48 kHz): se corta antes.
    const int64_t max_frames = (0xFFFFFFFFll - 1024 * 1024) / 4;
    std::vector<int16_t> out;
    std::string failure;
    while (!stop_ && failure.empty()) {
      Sleep(10);
      if (silence) {
        UINT32 padding = 0;
        if (SUCCEEDED(silence_client->GetCurrentPadding(&padding)) && padding < silence_frames) {
          const UINT32 free = silence_frames - padding;
          BYTE* data = nullptr;
          if (SUCCEEDED(silence->GetBuffer(free, &data))) {
            silence->ReleaseBuffer(free, AUDCLNT_BUFFERFLAGS_SILENT);
          }
        }
      }
      UINT32 packet = 0;
      hr = capture->GetNextPacketSize(&packet);
      while (SUCCEEDED(hr) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) break;
        out.resize(static_cast<size_t>(frames) * 2);
        float peak = 0.0f;
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
          std::fill(out.begin(), out.end(), static_cast<int16_t>(0));
        } else {
          for (UINT32 i = 0; i < frames; i++) {
            const BYTE* frame = data + static_cast<size_t>(i) * format->nBlockAlign;
            const float left = read(frame);
            const float right = channels > 1 ? read(frame + bytes_per_sample) : left;
            peak = (std::max)(peak, (std::max)(std::fabs(left), std::fabs(right)));
            out[i * 2] = to16(left);
            out[i * 2 + 1] = to16(right);
          }
        }
        capture->ReleaseBuffer(frames);
        fwrite(out.data(), sizeof(int16_t), out.size(), file);
        frames_ += frames;
        if (peak > peak_.load()) peak_ = peak;
        if (frames_ >= max_frames) {
          failure = "Se llegó al máximo de un archivo WAV (unas 6 horas): la grabación se cortó ahí.";
          break;
        }
        hr = capture->GetNextPacketSize(&packet);
      }
      if (FAILED(hr) && failure.empty()) {
        failure = hr == AUDCLNT_E_DEVICE_INVALIDATED
                      ? "Se cambió o desconectó la salida de audio: la grabación se cortó ahí."
                      : "Se cortó la grabación de la salida de audio.";
      }
    }

    capture_client->Stop();
    if (silence_client) silence_client->Stop();
    WriteWavHeader(file, format->nSamplesPerSec, static_cast<uint32_t>(frames_.load() * 4));
    fclose(file);
    if (!failure.empty()) {
      std::lock_guard<std::mutex> lock(mutex_);
      error_ = failure;
    }
  }

  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable ready_;
  bool startup_done_ = false;
  std::string startup_error_;
  std::string error_;
  std::wstring path_;
  std::wstring device_id_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> running_{false};
  std::atomic<int64_t> frames_{0};
  std::atomic<float> peak_{0.0f};
  std::atomic<int> sample_rate_{0};
  std::atomic<int> source_channels_{0};
};

}  // namespace loopback

#endif  // RUNNER_LOOPBACK_RECORDER_H_
