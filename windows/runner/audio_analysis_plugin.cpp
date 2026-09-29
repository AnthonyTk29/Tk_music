#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include "audio_analysis_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ui_task_runner.h"

using Microsoft::WRL::ComPtr;

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = std::unique_ptr<flutter::MethodResult<EncodableValue>>;
using SharedResult = std::shared_ptr<Result>;
using Clock = std::chrono::steady_clock;

constexpr double kPi = 3.14159265358979323846;
constexpr int kSpectrumFftSize = 2048;
constexpr int kSpectrumFrameStepMs = 100;
constexpr int kSpectrumBandCount = 24;
constexpr int64_t kTicksPerSecond = 10000000;  // unidades de 100ns de MF

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

const EncodableValue* FindArg(const EncodableMap& args, const char* key) {
  auto it = args.find(EncodableValue(key));
  return it == args.end() ? nullptr : &it->second;
}

std::string GetString(const EncodableMap& args, const char* key) {
  const EncodableValue* value = FindArg(args, key);
  if (!value) return "";
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  return "";
}

int64_t GetInt(const EncodableMap& args, const char* key, int64_t fallback) {
  const EncodableValue* value = FindArg(args, key);
  if (!value) return fallback;
  if (const auto* v32 = std::get_if<int32_t>(value)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(value)) return *v64;
  return fallback;
}

double GetDouble(const EncodableMap& args, const char* key, double fallback) {
  const EncodableValue* value = FindArg(args, key);
  if (!value) return fallback;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* v32 = std::get_if<int32_t>(value)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(value)) return static_cast<double>(*v64);
  return fallback;
}

// COM por hilo de trabajo (Media Foundation lo necesita).
class ComScope {
 public:
  ComScope() : ok_(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {}
  ~ComScope() {
    if (ok_) CoUninitialize();
  }

 private:
  bool ok_;
};

// Lector de PCM de 16 bits intercalado sobre IMFSourceReader.
class PcmReader {
 public:
  bool Open(const std::string& path) {
    const std::wstring wide = Utf8ToWide(path);
    if (wide.empty() || FAILED(MFCreateSourceReaderFromURL(wide.c_str(), nullptr, &reader_))) {
      return false;
    }
    const DWORD audio = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
    reader_->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    if (FAILED(reader_->SetStreamSelection(audio, TRUE))) return false;

    ComPtr<IMFMediaType> type;
    if (FAILED(MFCreateMediaType(&type))) return false;
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (FAILED(reader_->SetCurrentMediaType(audio, nullptr, type.Get()))) return false;

    ComPtr<IMFMediaType> actual;
    if (FAILED(reader_->GetCurrentMediaType(audio, &actual))) return false;
    UINT32 rate = 0;
    UINT32 channels = 0;
    actual->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    actual->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
    if (rate == 0 || channels == 0) return false;
    sample_rate_ = static_cast<int>(rate);
    channels_ = static_cast<int>(channels);

    PROPVARIANT duration;
    PropVariantInit(&duration);
    if (SUCCEEDED(reader_->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &duration)) &&
        duration.vt == VT_UI8) {
      duration_ = static_cast<int64_t>(duration.uhVal.QuadPart);
    }
    PropVariantClear(&duration);
    return true;
  }

  bool Seek(int64_t position) {
    if (position <= 0) return true;
    PROPVARIANT target;
    PropVariantInit(&target);
    target.vt = VT_I8;
    target.hVal.QuadPart = position;
    const HRESULT hr = reader_->SetCurrentPosition(GUID_NULL, target);
    PropVariantClear(&target);
    return SUCCEEDED(hr);
  }

  // Siguiente bloque decodificado. false = fin del archivo o error.
  bool Read(std::vector<int16_t>* samples, int64_t* timestamp) {
    samples->clear();
    DWORD flags = 0;
    LONGLONG time = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader_->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0,
                                   nullptr, &flags, &time, &sample))) {
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) return false;
    *timestamp = time;
    if (!sample) return true;  // hueco sin datos: se sigue leyendo
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return false;
    BYTE* data = nullptr;
    DWORD length = 0;
    if (FAILED(buffer->Lock(&data, nullptr, &length))) return false;
    const size_t count = length / sizeof(int16_t);
    samples->resize(count);
    std::memcpy(samples->data(), data, count * sizeof(int16_t));
    buffer->Unlock();
    return true;
  }

  int sample_rate() const { return sample_rate_; }
  int channels() const { return channels_; }
  int64_t duration() const { return duration_; }

 private:
  ComPtr<IMFSourceReader> reader_;
  int sample_rate_ = 0;
  int channels_ = 0;
  int64_t duration_ = 0;
};

// ---- FFT (mismo algoritmo que SpectrumMath.kt) ----

void Fft(std::vector<double>& re, std::vector<double>& im) {
  const size_t n = re.size();
  size_t j = 0;
  for (size_t i = 1; i < n; ++i) {
    size_t bit = n >> 1;
    while (j & bit) {
      j ^= bit;
      bit >>= 1;
    }
    j |= bit;
    if (i < j) {
      std::swap(re[i], re[j]);
      std::swap(im[i], im[j]);
    }
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const double angle = -2.0 * kPi / static_cast<double>(len);
    const double wr = std::cos(angle);
    const double wi = std::sin(angle);
    for (size_t i = 0; i < n; i += len) {
      double cur_wr = 1.0;
      double cur_wi = 0.0;
      const size_t half = len / 2;
      for (size_t k = 0; k < half; ++k) {
        const double u_re = re[i + k];
        const double u_im = im[i + k];
        const double v_re = re[i + k + half] * cur_wr - im[i + k + half] * cur_wi;
        const double v_im = re[i + k + half] * cur_wi + im[i + k + half] * cur_wr;
        re[i + k] = u_re + v_re;
        im[i + k] = u_im + v_im;
        re[i + k + half] = u_re - v_re;
        im[i + k + half] = u_im - v_im;
        const double next_wr = cur_wr * wr - cur_wi * wi;
        const double next_wi = cur_wr * wi + cur_wi * wr;
        cur_wr = next_wr;
        cur_wi = next_wi;
      }
    }
  }
}

// Hann + FFT + agrupado logarítmico en bandas 0..1 (ver SpectrumMath.kt:
// misma referencia de 0 dBFS y mismo rango -55..-5 dB).
std::vector<double> ToBands(const std::vector<int16_t>& window) {
  const size_t n = window.size();
  std::vector<double> re(n);
  std::vector<double> im(n, 0.0);
  for (size_t i = 0; i < n; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) /
                                          static_cast<double>(n - 1));
    re[i] = window[i] * w;
  }
  Fft(re, im);
  const size_t bins = n / 2;
  std::vector<double> magnitudes(bins);
  for (size_t i = 0; i < bins; ++i) magnitudes[i] = std::hypot(re[i], im[i]);

  std::vector<double> bands(kSpectrumBandCount, 0.0);
  const double max_magnitude = 32768.0 * static_cast<double>(n) / 4.0;
  const double bin_count = static_cast<double>(bins);
  for (int b = 0; b < kSpectrumBandCount; ++b) {
    const int last = static_cast<int>(bins) - 1;
    const int start = std::clamp(
        static_cast<int>(std::pow(bin_count, static_cast<double>(b) / kSpectrumBandCount)), 1,
        last);
    const int end = std::clamp(
        static_cast<int>(std::pow(bin_count, static_cast<double>(b + 1) / kSpectrumBandCount)),
        start + 1, static_cast<int>(bins));
    double peak = 0.0;
    for (int i = start; i < end; ++i) peak = std::max(peak, magnitudes[static_cast<size_t>(i)]);
    const double db = peak > 0 ? 20.0 * std::log10(peak / max_magnitude) : -100.0;
    bands[static_cast<size_t>(b)] = std::clamp((db + 55.0) / 50.0, 0.0, 1.0);
  }
  return bands;
}

class AudioAnalysisPlugin {
 public:
  explicit AudioAnalysisPlugin(flutter::PluginRegistrarWindows* registrar) {
    MFStartup(MF_VERSION, MFSTARTUP_LITE);
    const auto& codec = flutter::StandardMethodCodec::GetInstance();

    analysis_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/audio_analysis", &codec);
    analysis_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
          HandleAnalysis(call, std::move(result));
        });

    spectrum_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "tk_music/spectrum_analysis", &codec);
    spectrum_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
          HandleSpectrum(call, std::move(result));
        });

    waveform_events_ = MakeEventChannel(registrar, "tk_music/audio_analysis/waveform_progress",
                                        &waveform_sink_);
    spectrum_events_ =
        MakeEventChannel(registrar, "tk_music/spectrum_analysis/progress", &spectrum_sink_);
  }

 private:
  using Sink = std::unique_ptr<flutter::EventSink<EncodableValue>>;

  static std::unique_ptr<flutter::EventChannel<EncodableValue>> MakeEventChannel(
      flutter::PluginRegistrarWindows* registrar, const char* name, Sink* sink) {
    auto channel = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), name, &flutter::StandardMethodCodec::GetInstance());
    channel->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
        [sink](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          *sink = std::move(events);
          return nullptr;
        },
        [sink](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          sink->reset();
          return nullptr;
        }));
    return channel;
  }

  static const EncodableMap& ArgsOf(const flutter::MethodCall<EncodableValue>& call) {
    static const EncodableMap kEmpty;
    const auto* map = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    return map ? *map : kEmpty;
  }

  void Reply(SharedResult result, EncodableValue value) {
    ui_.Post([result, value = std::move(value)]() { (*result)->Success(value); });
  }

  void ReplyError(SharedResult result, const char* code, const char* message) {
    ui_.Post([result, code = std::string(code), message = std::string(message)]() {
      (*result)->Error(code, message);
    });
  }

  void HandleAnalysis(const flutter::MethodCall<EncodableValue>& call, Result result) {
    const EncodableMap& args = ArgsOf(call);
    const std::string path = GetString(args, "path");
    if (path.empty()) {
      result->Error("BAD_ARGS", "Falta path");
      return;
    }
    auto shared = std::make_shared<Result>(std::move(result));
    if (call.method_name() == "decodePcm") {
      const int64_t start_ms = GetInt(args, "startMs", 0);
      const int seconds = static_cast<int>(std::clamp<int64_t>(GetInt(args, "seconds", 60), 1, 600));
      const int rate = static_cast<int>(std::clamp<int64_t>(GetInt(args, "sampleRate", 11025), 1000, 48000));
      std::thread([this, path, start_ms, seconds, rate, shared]() {
        DecodePcm(path, start_ms, seconds, rate, shared);
      }).detach();
    } else if (call.method_name() == "analyzeLoudness") {
      std::thread([this, path, shared]() { AnalyzeLoudness(path, shared); }).detach();
    } else if (call.method_name() == "analyzeWaveform") {
      const int buckets = static_cast<int>(std::clamp<int64_t>(GetInt(args, "buckets", 240), 1, 20000));
      const int64_t media_id = GetInt(args, "mediaStoreId", -1);
      const double fraction = GetDouble(args, "positionFraction", 0.0);
      const int request = ++waveform_request_;
      std::thread([this, path, buckets, media_id, fraction, request, shared]() {
        AnalyzeWaveform(path, buckets, media_id, fraction, request, shared);
      }).detach();
    } else {
      (*shared)->NotImplemented();
    }
  }

  void HandleSpectrum(const flutter::MethodCall<EncodableValue>& call, Result result) {
    if (call.method_name() != "analyzeSpectrogram") {
      result->NotImplemented();
      return;
    }
    const EncodableMap& args = ArgsOf(call);
    const std::string path = GetString(args, "path");
    if (path.empty()) {
      result->Error("BAD_ARGS", "Falta path");
      return;
    }
    const int64_t media_id = GetInt(args, "mediaStoreId", -1);
    const double fraction = GetDouble(args, "positionFraction", 0.0);
    const int request = ++spectrum_request_;
    auto shared = std::make_shared<Result>(std::move(result));
    std::thread([this, path, media_id, fraction, request, shared]() {
      AnalyzeSpectrogram(path, media_id, fraction, request, shared);
    }).detach();
  }

  // ---- PCM crudo para el análisis de BPM/tonalidad (en Dart) ----
  // Mono, bajado a [rate] Hz por promedio de bloques, 16 bits little-endian
  // — lo mismo que decodePcmBytes en MainActivity.kt.

  void DecodePcm(const std::string& path, int64_t start_ms, int seconds, int rate,
                 SharedResult result) {
    std::lock_guard<std::mutex> worker(loudness_worker_);
    ComScope com;
    PcmReader reader;
    if (!reader.Open(path)) {
      ReplyError(result, "DECODE_FAILED", "No se pudo decodificar el audio");
      return;
    }
    const int64_t window = static_cast<int64_t>(seconds) * kTicksPerSecond;
    int64_t start = std::max<int64_t>(start_ms, 0) * 10000;
    if (reader.duration() > 0 && start + window > reader.duration()) {
      start = std::max<int64_t>(reader.duration() - window, 0);
    }
    reader.Seek(start);
    int64_t first_time = -1;

    const size_t max_samples = static_cast<size_t>(seconds) * static_cast<size_t>(rate);
    std::vector<uint8_t> out;
    out.reserve(max_samples * 2);
    const int channels = reader.channels();
    const double step = static_cast<double>(reader.sample_rate()) / rate;
    double acc = 0;
    int acc_count = 0;
    double phase = 0;
    const auto deadline = Clock::now() + std::chrono::seconds(20);
    std::vector<int16_t> samples;
    int64_t time = 0;
    while (out.size() / 2 < max_samples && Clock::now() < deadline && reader.Read(&samples, &time)) {
      if (first_time < 0 && !samples.empty()) first_time = time;
      const size_t frames = samples.size() / static_cast<size_t>(channels);
      for (size_t f = 0; f < frames && out.size() / 2 < max_samples; ++f) {
        int sum = 0;
        for (int c = 0; c < channels; ++c) sum += samples[f * channels + c];
        acc += static_cast<double>(sum) / channels;
        acc_count++;
        phase += 1.0;
        if (phase >= step) {
          phase -= step;
          const int value = std::clamp(static_cast<int>(acc / acc_count), -32768, 32767);
          out.push_back(static_cast<uint8_t>(value & 0xFF));
          out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
          acc = 0;
          acc_count = 0;
        }
      }
    }
    EncodableMap map;
    map[EncodableValue("startMs")] =
        EncodableValue(static_cast<int64_t>((first_time >= 0 ? first_time : start) / 10000));
    map[EncodableValue("pcm")] = EncodableValue(out);
    Reply(result, EncodableValue(map));
  }

  // ---- Volumen (dB RMS de ~20s desde el 30% de la canción) ----

  void AnalyzeLoudness(const std::string& path, SharedResult result) {
    std::lock_guard<std::mutex> worker(loudness_worker_);
    ComScope com;
    PcmReader reader;
    if (!reader.Open(path)) {
      ReplyError(result, "ANALYZE_FAILED", "No se pudo analizar el audio");
      return;
    }
    const int64_t window = 20 * kTicksPerSecond;
    const int64_t start = reader.duration() > window * 2
                              ? static_cast<int64_t>(static_cast<double>(reader.duration()) * 0.3)
                              : 0;
    reader.Seek(start);
    const auto deadline = Clock::now() + std::chrono::seconds(15);
    double sum_squares = 0;
    int64_t count = 0;
    std::vector<int16_t> samples;
    int64_t time = 0;
    while (Clock::now() < deadline && reader.Read(&samples, &time)) {
      for (int16_t s : samples) sum_squares += static_cast<double>(s) * s;
      count += static_cast<int64_t>(samples.size());
      if (time - start > window) break;
    }
    double db = -23.0;
    if (count > 0) {
      const double rms = std::sqrt(sum_squares / static_cast<double>(count));
      const double value = 20.0 * std::log10(rms / 32768.0);
      if (std::isfinite(value)) db = std::clamp(value, -60.0, 0.0);
    }
    Reply(result, EncodableValue(db));
  }

  // ---- Forma de onda (picos por balde, primero desde el puntero) ----

  void AnalyzeWaveform(const std::string& path, int buckets, int64_t media_id, double fraction,
                       int request, SharedResult result) {
    std::lock_guard<std::mutex> worker(waveform_worker_);
    auto still_valid = [this, request]() { return waveform_request_.load() == request; };
    if (!still_valid()) {
      // Se pidió otra canción mientras esta esperaba su turno.
      ReplyError(result, "SUPERSEDED", "Se pidió otra canción antes de empezar");
      return;
    }
    ComScope com;
    std::vector<double> peaks(static_cast<size_t>(buckets), 0.0);
    const int start_bucket = std::clamp(static_cast<int>(fraction * buckets), 0, buckets - 1);

    auto emit = [this, media_id, still_valid](const std::vector<double>& snapshot) {
      if (!still_valid()) return;
      ui_.Post([this, media_id, snapshot]() {
        if (!waveform_sink_) return;
        EncodableMap event;
        event[EncodableValue("mediaStoreId")] = EncodableValue(media_id);
        event[EncodableValue("peaks")] = EncodableValue(snapshot);
        waveform_sink_->Success(EncodableValue(event));
      });
    };

    bool ok = DecodeWaveformRange(path, buckets, start_bucket, buckets, &peaks, still_valid, emit) &&
              still_valid();
    if (ok && start_bucket > 0) {
      ok = DecodeWaveformRange(path, buckets, 0, start_bucket, &peaks, still_valid, emit) &&
           still_valid();
    }
    if (ok) {
      Reply(result, EncodableValue(peaks));
    } else {
      ReplyError(result, "ANALYZE_FAILED", "No se pudo generar la forma de onda");
    }
  }

  template <typename Valid, typename Emit>
  bool DecodeWaveformRange(const std::string& path, int buckets, int from, int to,
                           std::vector<double>* peaks, Valid still_valid, Emit emit) {
    PcmReader reader;
    if (!reader.Open(path)) return false;
    const double duration = static_cast<double>(std::max<int64_t>(reader.duration(), 1));
    reader.Seek(static_cast<int64_t>(static_cast<double>(from) / buckets * duration));

    const int channels = reader.channels();
    const double ticks_per_frame = static_cast<double>(kTicksPerSecond) / reader.sample_rate();
    const auto deadline = Clock::now() + std::chrono::seconds(30);
    auto last_emit = Clock::now();
    std::vector<int16_t> samples;
    int64_t time = 0;
    bool reached_end = false;
    while (!reached_end && still_valid() && Clock::now() < deadline && reader.Read(&samples, &time)) {
      const size_t frames = samples.size() / static_cast<size_t>(channels);
      for (size_t f = 0; f < frames; ++f) {
        const double at = static_cast<double>(time) + static_cast<double>(f) * ticks_per_frame;
        const int bucket = std::clamp(static_cast<int>(at / duration * buckets), 0, buckets - 1);
        if (bucket >= to) {
          reached_end = true;
          break;
        }
        int peak = 0;
        for (int c = 0; c < channels; ++c) {
          peak = std::max(peak, std::abs(static_cast<int>(samples[f * channels + c])));
        }
        const double amplitude = std::min(1.0, peak / 32768.0);
        double& slot = (*peaks)[static_cast<size_t>(bucket)];
        if (amplitude > slot) slot = amplitude;
      }
      if (Clock::now() - last_emit > std::chrono::milliseconds(400)) {
        last_emit = Clock::now();
        emit(*peaks);
      }
    }
    emit(*peaks);
    return true;
  }

  // ---- Espectrograma (bandas cada 100ms, primero desde el puntero) ----

  void AnalyzeSpectrogram(const std::string& path, int64_t media_id, double fraction, int request,
                          SharedResult result) {
    std::lock_guard<std::mutex> worker(spectrum_worker_);
    auto still_valid = [this, request]() { return spectrum_request_.load() == request; };
    if (!still_valid()) {
      ReplyError(result, "SUPERSEDED", "Se pidió otra canción antes de empezar");
      return;
    }
    ComScope com;
    int64_t duration_ms = 0;
    {
      PcmReader probe;
      if (!probe.Open(path)) {
        ReplyError(result, "ANALYZE_FAILED", "No se pudo generar el espectrograma");
        return;
      }
      duration_ms = std::max<int64_t>(probe.duration() / 10000, 1000);
    }
    const int total_frames = std::max(1, static_cast<int>(duration_ms / kSpectrumFrameStepMs));
    std::vector<std::vector<double>> frames(static_cast<size_t>(total_frames),
                                            std::vector<double>(kSpectrumBandCount, 0.0));
    const int start_frame = std::clamp(static_cast<int>(fraction * total_frames), 0, total_frames - 1);

    auto emit = [this, media_id, still_valid](const std::vector<std::vector<double>>& snapshot) {
      if (!still_valid()) return;
      EncodableList list;
      list.reserve(snapshot.size());
      for (const auto& frame : snapshot) list.emplace_back(frame);
      ui_.Post([this, media_id, list = std::move(list)]() {
        if (!spectrum_sink_) return;
        EncodableMap event;
        event[EncodableValue("mediaStoreId")] = EncodableValue(media_id);
        event[EncodableValue("frames")] = EncodableValue(list);
        event[EncodableValue("frameStepMs")] = EncodableValue(kSpectrumFrameStepMs);
        spectrum_sink_->Success(EncodableValue(event));
      });
    };

    bool ok = DecodeSpectrogramRange(path, &frames, start_frame, total_frames, still_valid, emit) &&
              still_valid();
    if (ok && start_frame > 0) {
      ok = DecodeSpectrogramRange(path, &frames, 0, start_frame, still_valid, emit) && still_valid();
    }
    if (!ok) {
      ReplyError(result, "ANALYZE_FAILED", "No se pudo generar el espectrograma");
      return;
    }
    EncodableList list;
    list.reserve(frames.size());
    for (const auto& frame : frames) list.emplace_back(frame);
    EncodableMap map;
    map[EncodableValue("frames")] = EncodableValue(list);
    map[EncodableValue("frameStepMs")] = EncodableValue(kSpectrumFrameStepMs);
    Reply(result, EncodableValue(map));
  }

  template <typename Valid, typename Emit>
  bool DecodeSpectrogramRange(const std::string& path, std::vector<std::vector<double>>* frames,
                              int from, int to, Valid still_valid, Emit emit) {
    PcmReader reader;
    if (!reader.Open(path)) return false;
    reader.Seek(static_cast<int64_t>(from) * kSpectrumFrameStepMs * 10000);

    const int channels = reader.channels();
    const int step_samples =
        std::max(1, static_cast<int>(static_cast<int64_t>(reader.sample_rate()) *
                                     kSpectrumFrameStepMs / 1000));
    const double ms_per_frame = 1000.0 / reader.sample_rate();
    const auto deadline = Clock::now() + std::chrono::seconds(30);
    auto last_emit = Clock::now();
    std::vector<int16_t> window(kSpectrumFftSize, 0);
    int since_window_start = 0;
    std::vector<int16_t> samples;
    int64_t time = 0;
    bool reached_end = false;
    while (!reached_end && still_valid() && Clock::now() < deadline && reader.Read(&samples, &time)) {
      const size_t count = samples.size() / static_cast<size_t>(channels);
      const double base_ms = static_cast<double>(time) / 10000.0;
      for (size_t f = 0; f < count && !reached_end; ++f) {
        int sum = 0;
        for (int c = 0; c < channels; ++c) sum += samples[f * channels + c];
        const int16_t mono = static_cast<int16_t>(sum / channels);
        if (since_window_start < kSpectrumFftSize) window[static_cast<size_t>(since_window_start)] = mono;
        since_window_start++;
        if (since_window_start >= step_samples) {
          if (since_window_start >= kSpectrumFftSize) {
            const int frame_index = static_cast<int>(
                (base_ms + static_cast<double>(f) * ms_per_frame) / kSpectrumFrameStepMs);
            if (frame_index >= to) {
              reached_end = true;
            } else if (frame_index >= 0 && frame_index < static_cast<int>(frames->size())) {
              (*frames)[static_cast<size_t>(frame_index)] = ToBands(window);
            }
          }
          since_window_start = 0;
        }
      }
      if (Clock::now() - last_emit > std::chrono::milliseconds(500)) {
        last_emit = Clock::now();
        emit(*frames);
      }
    }
    emit(*frames);
    return true;
  }

  UiTaskRunner ui_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> analysis_channel_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> spectrum_channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> waveform_events_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> spectrum_events_;
  Sink waveform_sink_;
  Sink spectrum_sink_;
  std::atomic<int> waveform_request_{0};
  std::atomic<int> spectrum_request_{0};
  std::mutex waveform_worker_;
  std::mutex spectrum_worker_;
  std::mutex loudness_worker_;
};

}  // namespace

void RegisterAudioAnalysisPlugin(flutter::PluginRegistrarWindows* registrar) {
  // Vive lo que vive el proceso, igual que BluetoothSyncPlugin.
  static AudioAnalysisPlugin* plugin = new AudioAnalysisPlugin(registrar);
  (void)plugin;
}
