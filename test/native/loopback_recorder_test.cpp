// Prueba real de windows/runner/loopback_recorder.h ("Grabar mezcla"):
// graba ~2 s de la salida de audio mientras suena un tono bajito SOLO por el
// canal izquierdo, y revisa el WAV:
//  - dura lo que se grabó aunque haya silencios (el flujo de silencio
//    mantiene viva la captura),
//  - es estéreo de 16 bits,
//  - el tono quedó a la izquierda y no a la derecha.
//
// Compilar y correr (Developer Command Prompt de VS, desde la raíz):
//   cl /nologo /EHsc /std:c++17 /I windows\runner test\native\loopback_recorder_test.cpp ^
//      ole32.lib shell32.lib winmm.lib /Fe:build\loopback_recorder_test.exe
//   build\loopback_recorder_test.exe
#include "loopback_recorder.h"

#include <mmsystem.h>

#include <cstdio>
#include <vector>

namespace {

constexpr int kRate = 48000;

// Tono de 440 Hz a -26 dB solo por la izquierda, con waveOut (otro camino
// que WASAPI compartido: llega a la misma mezcla del sistema).
bool PlayLeftTone(double seconds, HWAVEOUT* out, WAVEHDR* header, std::vector<int16_t>* pcm) {
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 2;
  format.nSamplesPerSec = kRate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = 4;
  format.nAvgBytesPerSec = kRate * 4;
  if (waveOutOpen(out, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) {
    return false;
  }
  const int frames = static_cast<int>(seconds * kRate);
  pcm->assign(static_cast<size_t>(frames) * 2, 0);
  for (int i = 0; i < frames; i++) {
    (*pcm)[i * 2] = static_cast<int16_t>(1600 * std::sin(2 * 3.14159265 * 440 * i / kRate));
  }
  *header = WAVEHDR{};
  header->lpData = reinterpret_cast<LPSTR>(pcm->data());
  header->dwBufferLength = static_cast<DWORD>(pcm->size() * sizeof(int16_t));
  waveOutPrepareHeader(*out, header, sizeof(WAVEHDR));
  waveOutWrite(*out, header, sizeof(WAVEHDR));
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  // Con un argumento: graba esa salida (el "{guid}" que usa mpv) en vez
  // de la predeterminada; el tono sale por la predeterminada, así que ahí
  // solo se revisa el archivo.
  std::wstring device;
  if (argc > 1) {
    const std::string arg(argv[1]);
    device.assign(arg.begin(), arg.end());
  }
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  wchar_t temp[MAX_PATH];
  GetTempPathW(MAX_PATH, temp);
  const std::wstring path = std::wstring(temp) + L"tk_music_loopback_test.wav";

  loopback::Recorder recorder;
  const std::string error = recorder.Start(path, device);
  if (!error.empty()) {
    std::printf("SKIP: no se pudo grabar (%s)\n", error.c_str());
    return 0;
  }
  std::printf("salida: %d Hz, %d canales\n", recorder.sample_rate(), recorder.source_channels());

  Sleep(500);  // medio segundo de silencio
  HWAVEOUT out = nullptr;
  WAVEHDR header;
  std::vector<int16_t> pcm;
  const bool tone = PlayLeftTone(1.0, &out, &header, &pcm);
  Sleep(1500);
  recorder.Stop();
  if (tone) {
    waveOutReset(out);
    waveOutUnprepareHeader(out, &header, sizeof(WAVEHDR));
    waveOutClose(out);
  }

  FILE* file = nullptr;
  if (_wfopen_s(&file, path.c_str(), L"rb") != 0 || !file) {
    std::printf("FALLA: no quedó el archivo\n");
    return 1;
  }
  std::vector<uint8_t> bytes;
  uint8_t chunk[65536];
  size_t n;
  while ((n = fread(chunk, 1, sizeof(chunk), file)) > 0) bytes.insert(bytes.end(), chunk, chunk + n);
  fclose(file);
  DeleteFileW(path.c_str());

  int failures = 0;
  auto check = [&failures](bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "ok   " : "FALLA", what);
    if (!ok) failures++;
  };
  check(bytes.size() > 44 && std::memcmp(bytes.data(), "RIFF", 4) == 0 &&
            std::memcmp(bytes.data() + 8, "WAVE", 4) == 0,
        "encabezado RIFF/WAVE");
  uint16_t channels, bits;
  uint32_t rate, data_size, riff_size;
  std::memcpy(&riff_size, bytes.data() + 4, 4);
  std::memcpy(&channels, bytes.data() + 22, 2);
  std::memcpy(&rate, bytes.data() + 24, 4);
  std::memcpy(&bits, bytes.data() + 34, 2);
  std::memcpy(&data_size, bytes.data() + 40, 4);
  check(channels == 2 && bits == 16, "estéreo de 16 bits");
  check(data_size == bytes.size() - 44 && riff_size == bytes.size() - 8,
        "tamaños del encabezado cerrados bien");
  const double seconds = static_cast<double>(data_size) / 4 / rate;
  std::printf("      duración grabada: %.2f s\n", seconds);
  check(seconds > 1.7 && seconds < 2.6, "dura lo grabado (con los silencios)");
  check(recorder.duration_ms() / 1000.0 > 1.7, "duration_ms informa lo mismo");

  const int16_t* samples = reinterpret_cast<const int16_t*>(bytes.data() + 44);
  const size_t frames = data_size / 4;
  double left = 0, right = 0;
  for (size_t i = 0; i < frames; i++) {
    left += static_cast<double>(samples[i * 2]) * samples[i * 2];
    right += static_cast<double>(samples[i * 2 + 1]) * samples[i * 2 + 1];
  }
  left = std::sqrt(left / (frames ? frames : 1));
  right = std::sqrt(right / (frames ? frames : 1));
  std::printf("      RMS izquierda %.1f, derecha %.1f\n", left, right);
  if (tone && device.empty()) {
    check(left > 50, "el tono quedó grabado");
    check(left > right * 4, "el tono quedó a la izquierda (estéreo respetado)");
  }
  std::printf(failures == 0 ? "TODO OK\n" : "%d FALLAS\n", failures);
  return failures == 0 ? 0 : 1;
}
