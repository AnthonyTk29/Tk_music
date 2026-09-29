#ifndef RUNNER_AUDIO_FILE_TOOLS_H_
#define RUNNER_AUDIO_FILE_TOOLS_H_

// Calidad de un archivo de audio y "mandar a la papelera", para el gestor
// de archivos del Modo DJ. Sin nada de Flutter, para poder probarlo solo
// (test/native/audio_file_tools_test.cpp). Lo usa desktop_media_plugin.cpp.

#include <windows.h>
#include <propsys.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>

namespace audio_file_tools {

struct AudioFileInfo {
  uint32_t bitrate = 0;  // bits por segundo
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint32_t bits_per_sample = 0;
  uint64_t duration_ms = 0;
  bool has_vbr = false;
  bool vbr = false;
};

// Del sistema de propiedades de Windows (lo que muestra el Explorador).
inline AudioFileInfo ReadAudioFileInfo(const std::wstring& path) {
  AudioFileInfo info;
  Microsoft::WRL::ComPtr<IPropertyStore> store;
  if (path.empty() || FAILED(SHGetPropertyStoreFromParsingName(path.c_str(), nullptr, GPS_DEFAULT,
                                                               IID_PPV_ARGS(&store)))) {
    return info;
  }
  auto read_uint = [&store](const PROPERTYKEY& key) -> uint32_t {
    PROPVARIANT value;
    PropVariantInit(&value);
    ULONG number = 0;
    if (FAILED(store->GetValue(key, &value)) || FAILED(PropVariantToUInt32(value, &number))) {
      number = 0;
    }
    PropVariantClear(&value);
    return number;
  };
  info.bitrate = read_uint(PKEY_Audio_EncodingBitrate);
  info.sample_rate = read_uint(PKEY_Audio_SampleRate);
  info.channels = read_uint(PKEY_Audio_ChannelCount);
  info.bits_per_sample = read_uint(PKEY_Audio_SampleSize);

  PROPVARIANT vbr;
  PropVariantInit(&vbr);
  BOOL is_vbr = FALSE;
  if (SUCCEEDED(store->GetValue(PKEY_Audio_IsVariableBitRate, &vbr)) &&
      SUCCEEDED(PropVariantToBoolean(vbr, &is_vbr))) {
    info.has_vbr = true;
    info.vbr = is_vbr != FALSE;
  }
  PropVariantClear(&vbr);

  PROPVARIANT duration;
  PropVariantInit(&duration);
  ULONGLONG ticks = 0;
  if (SUCCEEDED(store->GetValue(PKEY_Media_Duration, &duration)) &&
      SUCCEEDED(PropVariantToUInt64(duration, &ticks))) {
    info.duration_ms = ticks / 10000;
  }
  PropVariantClear(&duration);
  return info;
}

// Manda un archivo a la Papelera de reciclaje (se puede recuperar desde
// ahí). Devuelve si ya no está en su lugar.
inline bool MoveToRecycleBin(const std::wstring& path) {
  if (path.empty()) return false;
  std::wstring from = path;
  from.push_back(L'\0');  // SHFileOperation pide doble terminador.
  SHFILEOPSTRUCTW op = {};
  op.wFunc = FO_DELETE;
  op.pFrom = from.c_str();
  op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
  return SHFileOperationW(&op) == 0 && !op.fAnyOperationsAborted &&
         GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES;
}

}  // namespace audio_file_tools

#endif  // RUNNER_AUDIO_FILE_TOOLS_H_
