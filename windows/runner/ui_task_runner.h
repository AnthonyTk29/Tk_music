#ifndef RUNNER_UI_TASK_RUNNER_H_
#define RUNNER_UI_TASK_RUNNER_H_

#include <windows.h>

#include <functional>
#include <mutex>
#include <vector>

// Ejecuta tareas en el hilo de la UI (el que registró los canales de
// Flutter) desde cualquier hilo de fondo: no hay garantía de que el
// EventSink o un MethodResult sean seguros fuera de ese hilo. Las tareas se
// encolan y se le avisa a una ventana oculta de solo-mensajes, que las
// corre en su propio hilo — el mismo esquema que usa BluetoothSyncPlugin.
class UiTaskRunner {
 public:
  UiTaskRunner();
  ~UiTaskRunner();

  UiTaskRunner(const UiTaskRunner&) = delete;
  UiTaskRunner& operator=(const UiTaskRunner&) = delete;

  void Post(std::function<void()> task);

 private:
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

  HWND window_ = nullptr;
  std::mutex mutex_;
  std::vector<std::function<void()>> tasks_;
};

#endif  // RUNNER_UI_TASK_RUNNER_H_
