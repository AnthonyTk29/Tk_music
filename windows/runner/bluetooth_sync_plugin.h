#ifndef RUNNER_BLUETOOTH_SYNC_PLUGIN_H_
#define RUNNER_BLUETOOTH_SYNC_PLUGIN_H_

// Este header NO incluye <winsock2.h>/<ws2bth.h> a propósito: el runner no
// define WIN32_LEAN_AND_MEAN, así que <windows.h> ya trae el <winsock.h>
// viejo, y cualquier archivo que incluya <windows.h> antes que winsock2
// (flutter_window.cpp, por ejemplo) no compilaría. Los sockets se guardan
// como uintptr_t (es el mismo tipo que SOCKET en Windows) y todo lo que
// necesita tipos de Winsock/Bluetooth vive en el .cpp.
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// Transporte Bluetooth Classic (RFCOMM) para "Sincronizar con otro
// dispositivo" en Windows — espejo de BluetoothSyncBridge.kt (Android): mismo
// framing ([1 byte tipo][4 bytes tamaño big-endian][payload]; tipo 1 =
// control JSON, 3 = inicio de archivo, 4 = trozo [8 bytes offset][bytes],
// 5 = archivo cancelado), mismo UUID de servicio y los mismos nombres de
// método/evento, para que
// bluetooth_sync_bridge.dart no tenga que saber en qué plataforma corre y
// para que un Windows pueda hablar con un Android.
class BluetoothSyncPlugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  BluetoothSyncPlugin();
  ~BluetoothSyncPlugin();

  BluetoothSyncPlugin(const BluetoothSyncPlugin&) = delete;
  BluetoothSyncPlugin& operator=(const BluetoothSyncPlugin&) = delete;

 private:
  struct Connection;

  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;
  using SharedResult = std::shared_ptr<Result>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        Result result);

  void GetPairedDevices(Result result);
  void GetCapacity(Result result);
  void GetLocalAdapter(Result result);
  void StartHosting(Result result);
  void ConnectToDevice(const std::string& address, Result result);
  struct OutgoingFile {
    std::string path;
    std::string title;
    std::string artist;
    int64_t duration_ms = 0;
    std::string transfer_id;
    std::string extra_json;
  };
  enum class SendOutcome { kOk, kFailed, kCancelled };

  void SendSongFileTo(const std::string& address, OutgoingFile file, Result result);
  void CancelTransfer(const std::string& address, Result result);
  void SendControl(const std::string& json, Result result);
  void SendControlTo(const std::string& address, const std::string& json,
                     Result result);
  void Disconnect(Result result);

  void AcceptLoop(uintptr_t server_socket);
  void OnConnected(uintptr_t client_socket, const std::string& address);
  void ReadLoop(std::shared_ptr<Connection> conn);
  bool WriteFrame(const std::shared_ptr<Connection>& conn, uint8_t type,
                  const std::string& payload);
  SendOutcome WriteSongFileTo(const std::shared_ptr<Connection>& conn,
                              const OutgoingFile& file);
  void StartIncomingFile(const std::shared_ptr<Connection>& conn, const std::string& meta);
  bool WriteIncomingChunk(const std::shared_ptr<Connection>& conn, const std::string& frame);
  void FinishIncomingFile(const std::shared_ptr<Connection>& conn);
  void AbortIncomingFile(const std::shared_ptr<Connection>& conn);
  void RemoveConnection(const std::shared_ptr<Connection>& conn,
                        const std::string& reason);
  std::shared_ptr<Connection> FindConnection(const std::string& address);
  std::vector<std::shared_ptr<Connection>> AllConnections();
  void UnregisterSdpService();

  // Los hilos de fondo (accept/lectura/escritura) no tocan el EventSink ni
  // el MethodResult directo — no hay garantía de que sea seguro fuera del
  // hilo que registró los canales. Encolan la tarea y le avisan a una
  // ventana oculta de solo-mensajes, que la ejecuta en ese hilo.
  void PostToUiThread(std::function<void()> task);
  void Reply(const SharedResult& result, bool ok, const std::string& code,
             const std::string& message);
  void EmitEvent(flutter::EncodableMap event);
  static LRESULT CALLBACK MessageWindowProc(HWND hwnd, UINT msg, WPARAM wparam,
                                            LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  std::map<std::string, std::shared_ptr<Connection>> connections_;
  std::mutex connections_mutex_;

  uintptr_t server_socket_;
  std::atomic<bool> running_{false};
  bool sdp_registered_ = false;
  bool winsock_ready_ = false;

  HWND message_window_ = nullptr;
  std::mutex task_queue_mutex_;
  std::vector<std::function<void()>> task_queue_;

  static constexpr int kMaxGuests = 6;
};

#endif  // RUNNER_BLUETOOTH_SYNC_PLUGIN_H_
