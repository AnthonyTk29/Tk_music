// winsock2 tiene que ir antes que cualquier <windows.h>: el runner no define
// WIN32_LEAN_AND_MEAN, así que si windows.h entra primero trae el winsock.h
// viejo y choca con este.
#include <winsock2.h>
#include <ws2bth.h>
#include <windows.h>
#include <bluetoothapis.h>

#include "bluetooth_sync_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <thread>

struct BluetoothSyncPlugin::Connection {
  std::string address;
  SOCKET socket = INVALID_SOCKET;
  // Cada frame se escribe entero sin soltar este lock. Los archivos viajan
  // en trozos (un frame cada uno), así que los mensajes de control se
  // cuelan entre trozo y trozo en vez de esperar al archivo completo.
  std::mutex write_mutex;
  // Un solo archivo saliente a la vez por conexión: los trozos de dos
  // archivos no se pueden mezclar en el mismo socket.
  std::mutex file_mutex;
  std::atomic<bool> cancel_outgoing{false};

  // Archivo entrante en curso. Solo lo toca el hilo de lectura.
  bool incoming_active = false;
  HANDLE incoming_handle = INVALID_HANDLE_VALUE;
  std::wstring incoming_path;
  std::string incoming_meta;
  std::string incoming_transfer_id;
  int64_t incoming_size = 0;
  int64_t incoming_received = 0;
  // Bytes disponibles = [0, head) ∪ [tail_from, tail_end).
  int64_t incoming_head = 0;
  int64_t incoming_tail_from = 0;
  int64_t incoming_tail_end = 0;
  int64_t incoming_last_emitted = 0;
};

namespace {

// Mismo UUID que SYNC_UUID en BluetoothSyncBridge.kt — los dos lados se
// encuentran por SDP con este valor.
// 8ce255c0-200a-11e0-ac64-0800200c9a66
constexpr GUID kSyncServiceUuid = {
    0x8ce255c0, 0x200a, 0x11e0, {0xac, 0x64, 0x08, 0x00, 0x20, 0x0c, 0x9a, 0x66}};

// Canal RFCOMM fijo del anfitrión en Windows (si está libre). El invitado
// Android lo prueba directo cuando la búsqueda por SDP falla (pasa con
// algunas placas Bluetooth de PC y algunos teléfonos): mismo valor que
// WINDOWS_HOST_CHANNEL en BluetoothSyncBridge.kt.
constexpr ULONG kPreferredChannel = 22;

constexpr UINT kTaskMessage = WM_APP + 1;
constexpr wchar_t kMessageWindowClass[] = L"TkMusicBluetoothSyncMessageWindow";
constexpr int64_t kProgressStep = 64 * 1024;
constexpr int64_t kChunkSize = 32 * 1024;
// El final del archivo viaja primero: ahí están los tags ID3v1 (MP3) o el
// índice "moov" (M4A) que el reproductor lee antes de arrancar — sin esto no
// podría empezar a sonar hasta tener el archivo completo.
constexpr int64_t kTailSize = 256 * 1024;

constexpr uint8_t kFrameControl = 1;
constexpr uint8_t kFrameFileStart = 3;
constexpr uint8_t kFrameFileChunk = 4;
constexpr uint8_t kFrameFileAbort = 5;

// El registro SDP se guarda acá (no en el header, que no puede ver tipos
// de ws2bth) para poder darlo de baja al desconectar: si no, al volver a
// ser anfitrión quedaba un registro viejo apuntando a un canal cerrado y
// el invitado podía intentar conectarse a ese.
SOCKADDR_BTH g_sdp_local_addr = {};
CSADDR_INFO g_sdp_csaddr = {};
std::wstring g_sdp_service_name = L"tk_music_sync";
GUID g_sdp_service_uuid = kSyncServiceUuid;

WSAQUERYSETW BuildSdpQuery() {
  WSAQUERYSETW query = {};
  query.dwSize = sizeof(query);
  query.lpszServiceInstanceName = g_sdp_service_name.data();
  query.lpServiceClassId = &g_sdp_service_uuid;
  query.dwNameSpace = NS_BTH;
  query.dwNumberOfCsAddrs = 1;
  query.lpcsaBuffer = &g_sdp_csaddr;
  return query;
}

std::string BthAddrToString(BTH_ADDR addr) {
  std::ostringstream out;
  out << std::hex << std::uppercase << std::setfill('0');
  for (int shift = 40; shift >= 0; shift -= 8) {
    out << std::setw(2) << static_cast<unsigned int>((addr >> shift) & 0xFF);
    if (shift > 0) out << ":";
  }
  return out.str();
}

// Sin std::stoul: el runner compila con _HAS_EXCEPTIONS=0, así que una
// dirección mal formada no se podría atrapar — strtoul no tira.
bool StringToBthAddr(const std::string& text, BTH_ADDR* out_addr) {
  BTH_ADDR value = 0;
  int bytes = 0;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find(':', start);
    if (end == std::string::npos) end = text.size();
    std::string part = text.substr(start, end - start);
    if (part.empty() || part.size() > 2) return false;
    char* parse_end = nullptr;
    unsigned long byte = std::strtoul(part.c_str(), &parse_end, 16);
    if (parse_end == part.c_str() || *parse_end != '\0' || byte > 0xFF) return false;
    value = (value << 8) | static_cast<BTH_ADDR>(byte);
    bytes++;
    start = end + 1;
  }
  if (bytes != 6) return false;
  *out_addr = value;
  return true;
}

std::string WideToUtf8(const wchar_t* wide) {
  if (!wide || !*wide) return "";
  int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return "";
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return L"";
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

std::string GetArgString(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return "";
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return "";
}

int64_t GetArgInt(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return 0;
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) return *v32;
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) return *v64;
  return 0;
}

// ---- JSON mínimo para la metadata de archivo ----
// Solo hace falta un objeto plano con un puñado de campos conocidos, así que
// no vale la pena sumar una librería de JSON. Lo que sí importa es escapar
// bien: un título con comillas o barras rompía el parseo del otro lado
// (JSONObject en Android) y cortaba la conexión.

std::string JsonEscape(const std::string& text) {
  std::string out;
  out.reserve(text.size() + 8);
  for (char ch : text) {
    const unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", static_cast<unsigned int>(c));
          out += buffer;
        } else {
          out += ch;
        }
    }
  }
  return out;
}

void AppendUtf8(std::string* out, unsigned long code) {
  if (code < 0x80) {
    *out += static_cast<char>(code);
  } else if (code < 0x800) {
    *out += static_cast<char>(0xC0 | (code >> 6));
    *out += static_cast<char>(0x80 | (code & 0x3F));
  } else {
    *out += static_cast<char>(0xE0 | (code >> 12));
    *out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
    *out += static_cast<char>(0x80 | (code & 0x3F));
  }
}

bool JsonFindValue(const std::string& json, const std::string& key, size_t* position) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return false;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return false;
  pos++;
  while (pos < json.size() &&
         (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) {
    pos++;
  }
  *position = pos;
  return pos < json.size();
}

std::string JsonGetString(const std::string& json, const std::string& key) {
  size_t pos = 0;
  if (!JsonFindValue(json, key, &pos) || json[pos] != '"') return "";
  std::string out;
  for (size_t i = pos + 1; i < json.size(); ++i) {
    const char c = json[i];
    if (c == '"') return out;
    if (c != '\\' || i + 1 >= json.size()) {
      out += c;
      continue;
    }
    const char escaped = json[++i];
    switch (escaped) {
      case 'n': out += '\n'; break;
      case 'r': out += '\r'; break;
      case 't': out += '\t'; break;
      case 'b': out += '\b'; break;
      case 'f': out += '\f'; break;
      case 'u': {
        if (i + 4 >= json.size()) return out;
        const std::string hex = json.substr(i + 1, 4);
        AppendUtf8(&out, std::strtoul(hex.c_str(), nullptr, 16));
        i += 4;
        break;
      }
      default: out += escaped;  // \" \\ \/
    }
  }
  return out;
}

int64_t JsonGetInt(const std::string& json, const std::string& key) {
  size_t pos = 0;
  if (!JsonFindValue(json, key, &pos)) return 0;
  return static_cast<int64_t>(std::strtoll(json.c_str() + pos, nullptr, 10));
}

// ---- Escritura/lectura crudas sobre el socket ----

bool SendAll(SOCKET sock, const char* data, size_t length) {
  size_t sent = 0;
  while (sent < length) {
    const int chunk = static_cast<int>(std::min<size_t>(length - sent, 64 * 1024));
    const int n = send(sock, data + sent, chunk, 0);
    if (n == SOCKET_ERROR || n == 0) return false;
    sent += static_cast<size_t>(n);
  }
  return true;
}

bool RecvAll(SOCKET sock, char* data, size_t length) {
  size_t received = 0;
  while (received < length) {
    const int chunk = static_cast<int>(std::min<size_t>(length - received, 64 * 1024));
    const int n = recv(sock, data + received, chunk, 0);
    if (n <= 0) return false;
    received += static_cast<size_t>(n);
  }
  return true;
}

// Frame = [1 byte tipo][4 bytes tamaño big-endian][payload] — igual que
// DataOutputStream.writeByte + writeInt en Android. El que llama ya tiene
// tomado el write_mutex de la conexión.
bool WriteFrameLocked(SOCKET sock, uint8_t type, const std::string& payload) {
  const uint32_t length = static_cast<uint32_t>(payload.size());
  char header[5];
  header[0] = static_cast<char>(type);
  header[1] = static_cast<char>((length >> 24) & 0xFF);
  header[2] = static_cast<char>((length >> 16) & 0xFF);
  header[3] = static_cast<char>((length >> 8) & 0xFF);
  header[4] = static_cast<char>(length & 0xFF);
  if (!SendAll(sock, header, sizeof(header))) return false;
  return payload.empty() || SendAll(sock, payload.data(), payload.size());
}

flutter::EncodableMap MakeEvent(const char* type, const std::string& address) {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("type")] = flutter::EncodableValue(std::string(type));
  event[flutter::EncodableValue("address")] = flutter::EncodableValue(address);
  return event;
}

}  // namespace

// static
void BluetoothSyncPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  // Vive lo que vive el proceso (como un singleton): el registrar no se
  // destruye hasta cerrar la app.
  static BluetoothSyncPlugin* plugin = new BluetoothSyncPlugin();

  plugin->method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "tk_music/bluetooth_sync",
          &flutter::StandardMethodCodec::GetInstance());
  plugin->method_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call, Result result) {
        plugin->HandleMethodCall(call, std::move(result));
      });

  plugin->event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "tk_music/bluetooth_sync/events",
          &flutter::StandardMethodCodec::GetInstance());
  plugin->event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [](const flutter::EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin->event_sink_ = std::move(events);
            return nullptr;
          },
          [](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin->event_sink_.reset();
            return nullptr;
          }));
}

BluetoothSyncPlugin::BluetoothSyncPlugin() : server_socket_(INVALID_SOCKET) {
  WSADATA wsa_data;
  winsock_ready_ = WSAStartup(MAKEWORD(2, 2), &wsa_data) == 0;

  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &BluetoothSyncPlugin::MessageWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kMessageWindowClass;
  RegisterClassW(&window_class);
  message_window_ = CreateWindowExW(0, kMessageWindowClass, L"", 0, 0, 0, 0, 0,
                                    HWND_MESSAGE, nullptr, GetModuleHandle(nullptr),
                                    nullptr);
  if (message_window_) {
    SetWindowLongPtrW(message_window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
}

BluetoothSyncPlugin::~BluetoothSyncPlugin() {
  running_.store(false);
  UnregisterSdpService();
  if (server_socket_ != INVALID_SOCKET) closesocket(server_socket_);
  for (const auto& conn : AllConnections()) closesocket(conn->socket);
  if (message_window_) DestroyWindow(message_window_);
  if (winsock_ready_) WSACleanup();
}

void BluetoothSyncPlugin::PostToUiThread(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(task_queue_mutex_);
    task_queue_.push_back(std::move(task));
  }
  if (message_window_) PostMessageW(message_window_, kTaskMessage, 0, 0);
}

// static
LRESULT CALLBACK BluetoothSyncPlugin::MessageWindowProc(HWND hwnd, UINT msg,
                                                         WPARAM wparam, LPARAM lparam) {
  if (msg != kTaskMessage) return DefWindowProcW(hwnd, msg, wparam, lparam);
  auto* plugin = reinterpret_cast<BluetoothSyncPlugin*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!plugin) return 0;
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(plugin->task_queue_mutex_);
    pending.swap(plugin->task_queue_);
  }
  for (auto& task : pending) task();
  return 0;
}

void BluetoothSyncPlugin::Reply(const SharedResult& result, bool ok, const std::string& code,
                                const std::string& message) {
  PostToUiThread([result, ok, code, message]() {
    if (ok) {
      (*result)->Success();
    } else {
      (*result)->Error(code, message);
    }
  });
}

void BluetoothSyncPlugin::EmitEvent(flutter::EncodableMap event) {
  PostToUiThread([this, event = std::move(event)]() {
    if (event_sink_) event_sink_->Success(flutter::EncodableValue(event));
  });
}

void BluetoothSyncPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call, Result result) {
  const std::string& method = call.method_name();
  static const flutter::EncodableMap kNoArgs;
  const flutter::EncodableMap* maybe_args =
      call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
  const flutter::EncodableMap& args = maybe_args ? *maybe_args : kNoArgs;

  if (method == "getPairedDevices") {
    GetPairedDevices(std::move(result));
  } else if (method == "getCapacity") {
    GetCapacity(std::move(result));
  } else if (method == "getLocalAdapter") {
    GetLocalAdapter(std::move(result));
  } else if (method == "getActiveSessions") {
    // Emparejados con una conexión Bluetooth activa ahora mismo (cualquier
    // perfil: auriculares sonando, un teléfono conectado, etc.), igual que
    // el snapshot de ACL de Android.
    flutter::EncodableList active;
    BLUETOOTH_DEVICE_SEARCH_PARAMS search = {};
    search.dwSize = sizeof(search);
    search.fReturnAuthenticated = TRUE;
    search.fReturnConnected = TRUE;
    BLUETOOTH_DEVICE_INFO device = {};
    device.dwSize = sizeof(device);
    HBLUETOOTH_DEVICE_FIND find = BluetoothFindFirstDevice(&search, &device);
    if (find) {
      do {
        if (device.fConnected) {
          active.push_back(flutter::EncodableValue(BthAddrToString(device.Address.ullLong)));
        }
        device = {};
        device.dwSize = sizeof(device);
      } while (BluetoothFindNextDevice(find, &device));
      BluetoothFindDeviceClose(find);
    }
    result->Success(flutter::EncodableValue(active));
  } else if (method == "startHosting") {
    StartHosting(std::move(result));
  } else if (method == "connectToDevice") {
    ConnectToDevice(GetArgString(args, "address"), std::move(result));
  } else if (method == "sendSongFileTo") {
    OutgoingFile file;
    file.path = GetArgString(args, "path");
    file.title = GetArgString(args, "title");
    file.artist = GetArgString(args, "artist");
    file.duration_ms = GetArgInt(args, "durationMs");
    file.transfer_id = GetArgString(args, "transferId");
    file.extra_json = GetArgString(args, "extraJson");
    SendSongFileTo(GetArgString(args, "address"), std::move(file), std::move(result));
  } else if (method == "cancelTransfer") {
    CancelTransfer(GetArgString(args, "address"), std::move(result));
  } else if (method == "sendControl") {
    SendControl(GetArgString(args, "json"), std::move(result));
  } else if (method == "sendControlTo") {
    SendControlTo(GetArgString(args, "address"), GetArgString(args, "json"),
                  std::move(result));
  } else if (method == "disconnect") {
    Disconnect(std::move(result));
  } else {
    result->NotImplemented();
  }
}

// Nombre y dirección del Bluetooth de esta PC, para el QR de "Unirse con
// QR": el invitado lo busca entre sus emparejados.
void BluetoothSyncPlugin::GetLocalAdapter(Result result) {
  flutter::EncodableMap info;
  info[flutter::EncodableValue("name")] = flutter::EncodableValue();
  info[flutter::EncodableValue("address")] = flutter::EncodableValue();
  BLUETOOTH_FIND_RADIO_PARAMS params = {};
  params.dwSize = sizeof(params);
  HANDLE radio = nullptr;
  HBLUETOOTH_RADIO_FIND find = BluetoothFindFirstRadio(&params, &radio);
  if (find) {
    BLUETOOTH_RADIO_INFO radio_info = {};
    radio_info.dwSize = sizeof(radio_info);
    if (BluetoothGetRadioInfo(radio, &radio_info) == ERROR_SUCCESS) {
      info[flutter::EncodableValue("name")] =
          flutter::EncodableValue(WideToUtf8(radio_info.szName));
      info[flutter::EncodableValue("address")] =
          flutter::EncodableValue(BthAddrToString(radio_info.address.ullLong));
    }
    CloseHandle(radio);
    BluetoothFindRadioClose(find);
  }
  // Siendo anfitrión: el canal RFCOMM (el invitado lo usa si no encuentra
  // el servicio por SDP).
  if (sdp_registered_) {
    info[flutter::EncodableValue("channel")] =
        flutter::EncodableValue(static_cast<int32_t>(g_sdp_local_addr.port));
  }
  result->Success(flutter::EncodableValue(info));
}

void BluetoothSyncPlugin::GetPairedDevices(Result result) {
  flutter::EncodableList devices;
  BLUETOOTH_DEVICE_SEARCH_PARAMS search = {};
  search.dwSize = sizeof(search);
  search.fReturnAuthenticated = TRUE;
  search.fReturnRemembered = TRUE;
  search.fReturnConnected = TRUE;
  search.fReturnUnknown = FALSE;
  search.fIssueInquiry = FALSE;  // solo los ya emparejados, sin escanear

  BLUETOOTH_DEVICE_INFO device = {};
  device.dwSize = sizeof(device);
  HBLUETOOTH_DEVICE_FIND find = BluetoothFindFirstDevice(&search, &device);
  if (find) {
    do {
      const std::string address = BthAddrToString(device.Address.ullLong);
      std::string name = WideToUtf8(device.szName);
      if (name.empty()) name = address;
      flutter::EncodableMap entry;
      entry[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
      entry[flutter::EncodableValue("address")] = flutter::EncodableValue(address);
      devices.push_back(flutter::EncodableValue(entry));
      device = {};
      device.dwSize = sizeof(device);
    } while (BluetoothFindNextDevice(find, &device));
    BluetoothFindDeviceClose(find);
  }
  result->Success(flutter::EncodableValue(devices));
}

void BluetoothSyncPlugin::GetCapacity(Result result) {
  BLUETOOTH_FIND_RADIO_PARAMS radio_params = {};
  radio_params.dwSize = sizeof(radio_params);
  HANDLE radio = nullptr;
  HBLUETOOTH_RADIO_FIND find = BluetoothFindFirstRadio(&radio_params, &radio);
  const bool has_radio = find != nullptr;
  if (find) {
    BluetoothFindRadioClose(find);
    if (radio) CloseHandle(radio);
  }

  flutter::EncodableMap capacity;
  capacity[flutter::EncodableValue("supported")] = flutter::EncodableValue(has_radio);
  capacity[flutter::EncodableValue("maxConcurrent")] =
      flutter::EncodableValue(has_radio ? 7 : 0);
  capacity[flutter::EncodableValue("reason")] =
      has_radio ? flutter::EncodableValue() : flutter::EncodableValue(std::string("no_bluetooth"));
  result->Success(flutter::EncodableValue(capacity));
}

void BluetoothSyncPlugin::StartHosting(Result result) {
  if (!winsock_ready_) {
    result->Error("NO_ADAPTER", "Winsock no se pudo inicializar");
    return;
  }
  // Una sesión de anfitrión anterior que no se cerró bien: se limpia antes
  // de abrir otra (si no, el SDP viejo seguía publicado).
  UnregisterSdpService();
  if (server_socket_ != INVALID_SOCKET) {
    closesocket(server_socket_);
    server_socket_ = INVALID_SOCKET;
  }

  SOCKET server = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
  if (server == INVALID_SOCKET) {
    result->Error("HOST_FAILED", "No se pudo crear el socket RFCOMM (¿Bluetooth apagado?)");
    return;
  }

  SOCKADDR_BTH bind_addr = {};
  bind_addr.addressFamily = AF_BTH;
  bind_addr.btAddr = 0;                  // cualquier radio local
  bind_addr.port = kPreferredChannel;    // el canal conocido, si está libre
  bool bound =
      bind(server, reinterpret_cast<SOCKADDR*>(&bind_addr), sizeof(bind_addr)) != SOCKET_ERROR;
  if (!bound) {
    // Ocupado por otro programa: que el sistema asigne uno (va en el QR).
    closesocket(server);
    server = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    bind_addr.port = BT_PORT_ANY;
    bound = server != INVALID_SOCKET &&
            bind(server, reinterpret_cast<SOCKADDR*>(&bind_addr), sizeof(bind_addr)) != SOCKET_ERROR;
  }
  if (!bound || listen(server, kMaxGuests) == SOCKET_ERROR) {
    closesocket(server);
    result->Error("HOST_FAILED", "No se pudo escuchar conexiones Bluetooth");
    return;
  }

  // Publica el servicio por SDP con el mismo UUID que usa Android, así el
  // invitado lo encuentra con createRfcommSocketToServiceRecord(SYNC_UUID)
  // sin depender de un número de canal fijo.
  int addr_len = sizeof(g_sdp_local_addr);
  g_sdp_local_addr = {};
  if (getsockname(server, reinterpret_cast<SOCKADDR*>(&g_sdp_local_addr), &addr_len) ==
      SOCKET_ERROR) {
    closesocket(server);
    result->Error("HOST_FAILED", "No se pudo leer el canal Bluetooth asignado");
    return;
  }
  g_sdp_csaddr = {};
  g_sdp_csaddr.LocalAddr.lpSockaddr = reinterpret_cast<SOCKADDR*>(&g_sdp_local_addr);
  g_sdp_csaddr.LocalAddr.iSockaddrLength = sizeof(g_sdp_local_addr);
  g_sdp_csaddr.iSocketType = SOCK_STREAM;
  g_sdp_csaddr.iProtocol = BTHPROTO_RFCOMM;
  WSAQUERYSETW query = BuildSdpQuery();
  if (WSASetServiceW(&query, RNRSERVICE_REGISTER, 0) == SOCKET_ERROR) {
    closesocket(server);
    result->Error("HOST_FAILED", "No se pudo publicar el servicio Bluetooth (SDP)");
    return;
  }
  sdp_registered_ = true;

  server_socket_ = server;
  running_.store(true);
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("channel"),
       flutter::EncodableValue(static_cast<int32_t>(g_sdp_local_addr.port))},
  }));

  // Detached: termina solo cuando Disconnect() cierra el socket del
  // servidor (accept() vuelve con error). Guardarlo en un std::thread
  // miembro y reasignarlo en un segundo hosting abortaba el proceso.
  std::thread([this, server]() { AcceptLoop(server); }).detach();
}

void BluetoothSyncPlugin::UnregisterSdpService() {
  if (!sdp_registered_) return;
  WSAQUERYSETW query = BuildSdpQuery();
  WSASetServiceW(&query, RNRSERVICE_DELETE, 0);
  sdp_registered_ = false;
}

void BluetoothSyncPlugin::AcceptLoop(uintptr_t server_socket) {
  const SOCKET server = static_cast<SOCKET>(server_socket);
  while (running_.load()) {
    SOCKADDR_BTH remote = {};
    int remote_len = sizeof(remote);
    SOCKET client = accept(server, reinterpret_cast<SOCKADDR*>(&remote), &remote_len);
    if (client == INVALID_SOCKET) break;
    if (AllConnections().size() >= static_cast<size_t>(kMaxGuests)) {
      closesocket(client);
      continue;
    }
    OnConnected(client, BthAddrToString(remote.btAddr));
  }
}

void BluetoothSyncPlugin::ConnectToDevice(const std::string& address, Result result) {
  if (!winsock_ready_) {
    result->Error("NO_ADAPTER", "Winsock no se pudo inicializar");
    return;
  }
  BTH_ADDR remote = 0;
  if (!StringToBthAddr(address, &remote)) {
    result->Error("CONNECT_FAILED", "Dirección Bluetooth inválida");
    return;
  }
  SOCKET client = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
  if (client == INVALID_SOCKET) {
    result->Error("CONNECT_FAILED", "No se pudo crear el socket RFCOMM (¿Bluetooth apagado?)");
    return;
  }

  running_.store(true);
  auto shared = std::make_shared<Result>(std::move(result));
  // connect() bloquea (SDP + conexión), así que va en su propio hilo.
  std::thread([this, client, remote, address, shared]() {
    SOCKADDR_BTH target = {};
    target.addressFamily = AF_BTH;
    target.btAddr = remote;
    target.serviceClassId = kSyncServiceUuid;
    // port = 0 es lo que le pide a Windows resolver el canal por SDP con
    // serviceClassId. (BT_PORT_ANY es para bind(), no para connect().)
    target.port = 0;
    if (connect(client, reinterpret_cast<SOCKADDR*>(&target), sizeof(target)) == SOCKET_ERROR) {
      const int error = WSAGetLastError();
      closesocket(client);
      Reply(shared, false, "CONNECT_FAILED",
            "No se pudo conectar con el anfitrión (error " + std::to_string(error) + ")");
      return;
    }
    Reply(shared, true, "", "");
    OnConnected(client, address);
  }).detach();
}

void BluetoothSyncPlugin::OnConnected(uintptr_t client_socket, const std::string& address) {
  auto conn = std::make_shared<Connection>();
  conn->address = address;
  conn->socket = static_cast<SOCKET>(client_socket);
  {
    std::lock_guard<std::mutex> lock(connections_mutex_);
    connections_[address] = conn;
  }

  flutter::EncodableMap event = MakeEvent("connected", address);
  std::string name = address;
  BLUETOOTH_DEVICE_INFO info = {};
  info.dwSize = sizeof(info);
  BTH_ADDR raw = 0;
  if (StringToBthAddr(address, &raw)) {
    info.Address.ullLong = raw;
    if (BluetoothGetDeviceInfo(nullptr, &info) == ERROR_SUCCESS) {
      const std::string friendly = WideToUtf8(info.szName);
      if (!friendly.empty()) name = friendly;
    }
  }
  event[flutter::EncodableValue("deviceName")] = flutter::EncodableValue(name);
  EmitEvent(std::move(event));

  std::thread([this, conn]() { ReadLoop(conn); }).detach();
}

std::shared_ptr<BluetoothSyncPlugin::Connection> BluetoothSyncPlugin::FindConnection(
    const std::string& address) {
  std::lock_guard<std::mutex> lock(connections_mutex_);
  auto it = connections_.find(address);
  return it == connections_.end() ? nullptr : it->second;
}

std::vector<std::shared_ptr<BluetoothSyncPlugin::Connection>>
BluetoothSyncPlugin::AllConnections() {
  std::lock_guard<std::mutex> lock(connections_mutex_);
  std::vector<std::shared_ptr<Connection>> all;
  all.reserve(connections_.size());
  for (const auto& entry : connections_) all.push_back(entry.second);
  return all;
}

void BluetoothSyncPlugin::ReadLoop(std::shared_ptr<Connection> conn) {
  std::string failure;
  while (running_.load()) {
    char header[5];
    if (!RecvAll(conn->socket, header, sizeof(header))) {
      failure = "Se cerró la conexión";
      break;
    }
    const uint8_t frame_type = static_cast<uint8_t>(header[0]);
    const uint32_t length = (static_cast<uint32_t>(static_cast<uint8_t>(header[1])) << 24) |
                            (static_cast<uint32_t>(static_cast<uint8_t>(header[2])) << 16) |
                            (static_cast<uint32_t>(static_cast<uint8_t>(header[3])) << 8) |
                            static_cast<uint32_t>(static_cast<uint8_t>(header[4]));
    if (length > 16u * 1024 * 1024) {
      failure = "Frame inválido";
      break;
    }
    std::string payload(length, '\0');
    if (length > 0 && !RecvAll(conn->socket, payload.data(), payload.size())) {
      failure = "Se cerró la conexión";
      break;
    }

    if (frame_type == kFrameControl) {
      flutter::EncodableMap event = MakeEvent("message", conn->address);
      event[flutter::EncodableValue("json")] = flutter::EncodableValue(payload);
      EmitEvent(std::move(event));
    } else if (frame_type == kFrameFileStart) {
      StartIncomingFile(conn, payload);
    } else if (frame_type == kFrameFileChunk) {
      if (!WriteIncomingChunk(conn, payload)) {
        failure = "No se pudo guardar el archivo recibido";
        break;
      }
    } else if (frame_type == kFrameFileAbort) {
      AbortIncomingFile(conn);
    }
    // Cualquier otro tipo: se descarta el payload.
  }

  AbortIncomingFile(conn);
  RemoveConnection(conn, failure);
}

void BluetoothSyncPlugin::StartIncomingFile(const std::shared_ptr<Connection>& conn,
                                            const std::string& meta) {
  // Un archivo anterior que quedó a medias (el anfitrión pasó a otra canción
  // sin avisar): se descarta.
  AbortIncomingFile(conn);

  const std::string file_name = JsonGetString(meta, "fileName");
  const int64_t file_size = JsonGetInt(meta, "fileSize");

  wchar_t temp_dir[MAX_PATH];
  GetTempPathW(MAX_PATH, temp_dir);
  std::wstring safe_name = Utf8ToWide(file_name.empty() ? "sync_received.mp3" : file_name);
  std::replace_if(safe_name.begin(), safe_name.end(),
                  [](wchar_t c) { return wcschr(L"\\/:*?\"<>|", c) != nullptr; }, L'_');
  const std::wstring dest_path = std::wstring(temp_dir) + L"tk_music_sync_" +
                                 std::to_wstring(GetTickCount64()) + L"_" + safe_name;

  // Compartido para lectura: el servidor de streaming de Dart lee el archivo
  // mientras todavía se está escribiendo.
  HANDLE handle = CreateFileW(dest_path.c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return;  // los trozos se descartan
  LARGE_INTEGER size;
  size.QuadPart = file_size;
  SetFilePointerEx(handle, size, nullptr, FILE_BEGIN);
  SetEndOfFile(handle);

  conn->incoming_active = true;
  conn->incoming_handle = handle;
  conn->incoming_path = dest_path;
  conn->incoming_meta = meta;
  conn->incoming_transfer_id = JsonGetString(meta, "transferId");
  conn->incoming_size = file_size;
  conn->incoming_received = 0;
  conn->incoming_head = 0;
  conn->incoming_tail_from = file_size;
  conn->incoming_tail_end = file_size;
  conn->incoming_last_emitted = 0;

  flutter::EncodableMap event = MakeEvent("file_started", conn->address);
  event[flutter::EncodableValue("transferId")] =
      flutter::EncodableValue(conn->incoming_transfer_id);
  event[flutter::EncodableValue("path")] = flutter::EncodableValue(WideToUtf8(dest_path.c_str()));
  event[flutter::EncodableValue("total")] = flutter::EncodableValue(file_size);
  event[flutter::EncodableValue("meta")] = flutter::EncodableValue(meta);
  EmitEvent(std::move(event));

  if (file_size == 0) FinishIncomingFile(conn);
}

bool BluetoothSyncPlugin::WriteIncomingChunk(const std::shared_ptr<Connection>& conn,
                                             const std::string& frame) {
  if (frame.size() < 8) return false;
  if (!conn->incoming_active) return true;  // archivo ya descartado

  int64_t offset = 0;
  for (int i = 0; i < 8; ++i) {
    offset = (offset << 8) | static_cast<int64_t>(static_cast<uint8_t>(frame[i]));
  }
  const int64_t length = static_cast<int64_t>(frame.size()) - 8;
  if (offset < 0 || offset + length > conn->incoming_size) return false;

  LARGE_INTEGER position;
  position.QuadPart = offset;
  DWORD written = 0;
  if (!SetFilePointerEx(conn->incoming_handle, position, nullptr, FILE_BEGIN) ||
      !WriteFile(conn->incoming_handle, frame.data() + 8, static_cast<DWORD>(length), &written,
                 nullptr) ||
      written != static_cast<DWORD>(length)) {
    return false;
  }

  conn->incoming_received += length;
  if (offset == conn->incoming_head) {
    conn->incoming_head += length;
  } else {
    if (conn->incoming_tail_from == conn->incoming_size) conn->incoming_tail_end = offset;
    conn->incoming_tail_from = std::min(conn->incoming_tail_from, offset);
    conn->incoming_tail_end = std::max(conn->incoming_tail_end, offset + length);
  }

  const bool done = conn->incoming_received >= conn->incoming_size;
  if (done || conn->incoming_received - conn->incoming_last_emitted >= kProgressStep) {
    conn->incoming_last_emitted = conn->incoming_received;
    flutter::EncodableMap progress = MakeEvent("file_progress", conn->address);
    progress[flutter::EncodableValue("transferId")] =
        flutter::EncodableValue(conn->incoming_transfer_id);
    progress[flutter::EncodableValue("received")] =
        flutter::EncodableValue(conn->incoming_received);
    progress[flutter::EncodableValue("total")] = flutter::EncodableValue(conn->incoming_size);
    progress[flutter::EncodableValue("head")] = flutter::EncodableValue(conn->incoming_head);
    progress[flutter::EncodableValue("tailFrom")] =
        flutter::EncodableValue(conn->incoming_tail_from);
    progress[flutter::EncodableValue("tailEnd")] =
        flutter::EncodableValue(conn->incoming_tail_end);
    EmitEvent(std::move(progress));
  }
  if (done) FinishIncomingFile(conn);
  return true;
}

void BluetoothSyncPlugin::FinishIncomingFile(const std::shared_ptr<Connection>& conn) {
  if (!conn->incoming_active) return;
  CloseHandle(conn->incoming_handle);
  conn->incoming_handle = INVALID_HANDLE_VALUE;
  conn->incoming_active = false;

  const std::string& meta = conn->incoming_meta;
  flutter::EncodableMap event = MakeEvent("file_received", conn->address);
  event[flutter::EncodableValue("transferId")] =
      flutter::EncodableValue(conn->incoming_transfer_id);
  event[flutter::EncodableValue("path")] =
      flutter::EncodableValue(WideToUtf8(conn->incoming_path.c_str()));
  event[flutter::EncodableValue("title")] = flutter::EncodableValue(JsonGetString(meta, "title"));
  event[flutter::EncodableValue("artist")] =
      flutter::EncodableValue(JsonGetString(meta, "artist"));
  event[flutter::EncodableValue("durationMs")] =
      flutter::EncodableValue(JsonGetInt(meta, "durationMs"));
  event[flutter::EncodableValue("meta")] = flutter::EncodableValue(meta);
  EmitEvent(std::move(event));
}

void BluetoothSyncPlugin::AbortIncomingFile(const std::shared_ptr<Connection>& conn) {
  if (!conn->incoming_active) return;
  CloseHandle(conn->incoming_handle);
  conn->incoming_handle = INVALID_HANDLE_VALUE;
  conn->incoming_active = false;
  DeleteFileW(conn->incoming_path.c_str());

  flutter::EncodableMap event = MakeEvent("file_aborted", conn->address);
  event[flutter::EncodableValue("transferId")] =
      flutter::EncodableValue(conn->incoming_transfer_id);
  EmitEvent(std::move(event));
}

void BluetoothSyncPlugin::RemoveConnection(const std::shared_ptr<Connection>& conn,
                                           const std::string& reason) {
  bool was_ours = false;
  {
    std::lock_guard<std::mutex> lock(connections_mutex_);
    auto it = connections_.find(conn->address);
    if (it != connections_.end() && it->second == conn) {
      connections_.erase(it);
      was_ours = true;
    }
  }
  closesocket(conn->socket);
  // Si ya no estaba en el mapa, fue un Disconnect() pedido desde Dart — ahí
  // no hace falta avisar (igual que en BluetoothSyncBridge.kt).
  if (!was_ours) return;
  flutter::EncodableMap event = MakeEvent("disconnected", conn->address);
  event[flutter::EncodableValue("reason")] = flutter::EncodableValue(reason);
  EmitEvent(std::move(event));
}

bool BluetoothSyncPlugin::WriteFrame(const std::shared_ptr<Connection>& conn, uint8_t type,
                                     const std::string& payload) {
  std::lock_guard<std::mutex> lock(conn->write_mutex);
  return WriteFrameLocked(conn->socket, type, payload);
}

BluetoothSyncPlugin::SendOutcome BluetoothSyncPlugin::WriteSongFileTo(
    const std::shared_ptr<Connection>& conn, const OutgoingFile& file) {
  std::lock_guard<std::mutex> file_lock(conn->file_mutex);
  conn->cancel_outgoing.store(false);

  std::ifstream in(Utf8ToWide(file.path), std::ios::binary | std::ios::ate);
  if (!in) return SendOutcome::kFailed;
  const int64_t file_size = static_cast<int64_t>(in.tellg());

  const size_t last_sep = file.path.find_last_of("/\\");
  const std::string file_name =
      last_sep == std::string::npos ? file.path : file.path.substr(last_sep + 1);

  std::ostringstream meta;
  meta << "{\"transferId\":\"" << JsonEscape(file.transfer_id) << "\",\"fileName\":\""
       << JsonEscape(file_name) << "\",\"fileSize\":" << file_size << ",\"title\":\""
       << JsonEscape(file.title) << "\",\"artist\":\"" << JsonEscape(file.artist)
       << "\",\"durationMs\":" << file.duration_ms;
  // extraJson ya viene serializado desde Dart (jsonEncode).
  if (!file.extra_json.empty()) meta << ",\"extra\":" << file.extra_json;
  meta << "}";
  if (!WriteFrame(conn, kFrameFileStart, meta.str())) return SendOutcome::kFailed;

  // Primero el final del archivo, después el resto en orden (ver kTailSize).
  std::vector<std::pair<int64_t, int64_t>> ranges;
  if (file_size > 2 * kTailSize) {
    ranges.emplace_back(file_size - kTailSize, file_size);
    ranges.emplace_back(0, file_size - kTailSize);
  } else {
    ranges.emplace_back(0, file_size);
  }

  std::string frame;
  int64_t sent = 0;
  int64_t last_emitted = 0;
  for (const auto& range : ranges) {
    int64_t offset = range.first;
    while (offset < range.second) {
      if (conn->cancel_outgoing.load()) {
        WriteFrame(conn, kFrameFileAbort, file.transfer_id);
        return SendOutcome::kCancelled;
      }
      const int64_t n = std::min(kChunkSize, range.second - offset);
      frame.assign(static_cast<size_t>(8 + n), '\0');
      for (int i = 0; i < 8; ++i) {
        frame[static_cast<size_t>(i)] = static_cast<char>((offset >> (56 - 8 * i)) & 0xFF);
      }
      in.seekg(offset);
      in.read(frame.data() + 8, static_cast<std::streamsize>(n));
      if (in.gcount() != static_cast<std::streamsize>(n)) return SendOutcome::kFailed;
      if (!WriteFrame(conn, kFrameFileChunk, frame)) return SendOutcome::kFailed;

      offset += n;
      sent += n;
      if (sent == file_size || sent - last_emitted >= kProgressStep) {
        last_emitted = sent;
        flutter::EncodableMap progress = MakeEvent("send_progress", conn->address);
        progress[flutter::EncodableValue("transferId")] =
            flutter::EncodableValue(file.transfer_id);
        progress[flutter::EncodableValue("sent")] = flutter::EncodableValue(sent);
        progress[flutter::EncodableValue("total")] = flutter::EncodableValue(file_size);
        EmitEvent(std::move(progress));
      }
    }
  }
  return SendOutcome::kOk;
}

void BluetoothSyncPlugin::SendSongFileTo(const std::string& address, OutgoingFile file,
                                         Result result) {
  auto conn = FindConnection(address);
  if (!conn) {
    result->Error("NOT_CONNECTED", "Invitado no conectado");
    return;
  }
  auto shared = std::make_shared<Result>(std::move(result));
  std::thread([this, conn, file = std::move(file), shared]() {
    const SendOutcome outcome = WriteSongFileTo(conn, file);
    if (outcome == SendOutcome::kCancelled) {
      Reply(shared, false, "CANCELLED", "Envío cancelado");
    } else {
      Reply(shared, outcome == SendOutcome::kOk, "SEND_FAILED",
            "Se cortó el envío por Bluetooth");
    }
  }).detach();
}

void BluetoothSyncPlugin::CancelTransfer(const std::string& address, Result result) {
  // Solo corta el envío en curso a ese invitado (si hay uno): el hilo que
  // manda lo ve entre trozo y trozo, avisa con un frame de cancelación y
  // responde CANCELLED a su propio sendSongFileTo.
  if (auto conn = FindConnection(address)) conn->cancel_outgoing.store(true);
  result->Success();
}

void BluetoothSyncPlugin::SendControl(const std::string& json, Result result) {
  auto targets = AllConnections();
  if (targets.empty()) {
    result->Error("NOT_CONNECTED", "No hay conexión activa");
    return;
  }
  // En su propio hilo: se llama seguido (p. ej. cada 1s para la corrección
  // de drift) y send() puede bloquear — en el hilo de la UI congelaría la
  // app con cada envío.
  auto shared = std::make_shared<Result>(std::move(result));
  std::thread([this, targets, json, shared]() {
    bool ok = true;
    for (const auto& conn : targets) {
      if (!WriteFrame(conn, kFrameControl, json)) ok = false;
    }
    Reply(shared, ok, "SEND_FAILED", "No se pudo mandar el mensaje de control");
  }).detach();
}

void BluetoothSyncPlugin::SendControlTo(const std::string& address, const std::string& json,
                                        Result result) {
  auto conn = FindConnection(address);
  if (!conn) {
    result->Error("NOT_CONNECTED", "Invitado no conectado");
    return;
  }
  auto shared = std::make_shared<Result>(std::move(result));
  std::thread([this, conn, json, shared]() {
    Reply(shared, WriteFrame(conn, kFrameControl, json), "SEND_FAILED",
          "No se pudo mandar el mensaje de control");
  }).detach();
}

void BluetoothSyncPlugin::Disconnect(Result result) {
  running_.store(false);
  UnregisterSdpService();
  if (server_socket_ != INVALID_SOCKET) {
    closesocket(server_socket_);
    server_socket_ = INVALID_SOCKET;
  }
  std::vector<std::shared_ptr<Connection>> targets;
  {
    std::lock_guard<std::mutex> lock(connections_mutex_);
    for (const auto& entry : connections_) targets.push_back(entry.second);
    connections_.clear();
  }
  for (const auto& conn : targets) {
    conn->cancel_outgoing.store(true);
    closesocket(conn->socket);
  }
  result->Success();
}
