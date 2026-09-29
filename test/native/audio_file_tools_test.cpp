// Prueba real de windows/runner/audio_file_tools.h (gestor de archivos del
// Modo DJ):
//  - lee bitrate, frecuencia, canales, bits y duración de un WAV generado
//    acá (valores conocidos) y de los MP3 que se pasen como argumento
//    (solo lectura: no se tocan);
//  - manda a la Papelera un archivo de prueba creado acá y revisa que ya
//    no esté (queda en la Papelera como "tk_music_papelera_prueba.wav").
//
// Compilar (Developer Command Prompt de VS, desde la raíz):
//   cl /nologo /EHsc /std:c++17 /utf-8 /I windows\runner test\native\audio_file_tools_test.cpp ^
//      ole32.lib shell32.lib propsys.lib /Fe:build\native\audio_file_tools_test.exe
//   build\native\audio_file_tools_test.exe "C:\...\algo.mp3"
#include <initguid.h>

#include "audio_file_tools.h"

#include <cstdio>
#include <vector>

namespace {

// WAV estéreo de 16 bits a 44,1 kHz, [seconds] de silencio.
bool WriteWav(const std::wstring& path, int seconds) {
  const uint32_t rate = 44100;
  const uint32_t data = rate * 4 * seconds;
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"wb") != 0 || !f) return false;
  auto u16 = [f](uint16_t v) { fwrite(&v, 2, 1, f); };
  auto u32 = [f](uint32_t v) { fwrite(&v, 4, 1, f); };
  fwrite("RIFF", 1, 4, f);
  u32(36 + data);
  fwrite("WAVEfmt ", 1, 8, f);
  u32(16);
  u16(1);
  u16(2);
  u32(rate);
  u32(rate * 4);
  u16(4);
  u16(16);
  fwrite("data", 1, 4, f);
  u32(data);
  std::vector<char> zeros(data, 0);
  fwrite(zeros.data(), 1, zeros.size(), f);
  fclose(f);
  return true;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleOutputCP(CP_UTF8);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int failures = 0;
  auto check = [&failures](bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "ok   " : "FALLA", what);
    if (!ok) failures++;
  };

  wchar_t temp[MAX_PATH];
  GetTempPathW(MAX_PATH, temp);
  const std::wstring wav = std::wstring(temp) + L"tk_music_papelera_prueba.wav";
  check(WriteWav(wav, 3), "WAV de prueba creado");

  const auto info = audio_file_tools::ReadAudioFileInfo(wav);
  std::printf("      WAV: %u bps, %u Hz, %u canales, %u bits, %llu ms\n", info.bitrate,
              info.sample_rate, info.channels, info.bits_per_sample,
              static_cast<unsigned long long>(info.duration_ms));
  check(info.sample_rate == 44100, "frecuencia 44100");
  check(info.channels == 2, "estéreo");
  check(info.bits_per_sample == 16, "16 bits");
  check(info.duration_ms >= 2900 && info.duration_ms <= 3100, "dura 3 s");

  for (int i = 1; i < argc; i++) {
    const auto mp3 = audio_file_tools::ReadAudioFileInfo(argv[i]);
    std::printf("      MP3 %d: %u kbps%s, %u Hz, %u canales, %llu ms\n", i, mp3.bitrate / 1000,
                mp3.vbr ? " (VBR)" : "", mp3.sample_rate, mp3.channels,
                static_cast<unsigned long long>(mp3.duration_ms));
    check(mp3.bitrate > 0 && mp3.sample_rate > 0 && mp3.duration_ms > 0, "MP3 leído");
  }

  check(audio_file_tools::MoveToRecycleBin(wav), "mandado a la papelera");
  check(GetFileAttributesW(wav.c_str()) == INVALID_FILE_ATTRIBUTES, "ya no está en su carpeta");
  check(!audio_file_tools::MoveToRecycleBin(wav), "uno que no existe devuelve false");
  std::printf(failures == 0 ? "TODO OK\n" : "%d FALLAS\n", failures);
  return failures == 0 ? 0 : 1;
}
