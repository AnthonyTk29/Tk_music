#include "ui_task_runner.h"

namespace {

constexpr UINT kRunTasksMessage = WM_APP + 2;
constexpr wchar_t kWindowClass[] = L"TkMusicUiTaskRunnerWindow";

}  // namespace

UiTaskRunner::UiTaskRunner() {
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &UiTaskRunner::WindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kWindowClass;
  RegisterClassW(&window_class);  // falla (sin problema) si ya estaba registrada
  window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                            GetModuleHandle(nullptr), nullptr);
  if (window_) SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

UiTaskRunner::~UiTaskRunner() {
  if (window_) DestroyWindow(window_);
}

void UiTaskRunner::Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push_back(std::move(task));
  }
  if (window_) PostMessageW(window_, kRunTasksMessage, 0, 0);
}

// static
LRESULT CALLBACK UiTaskRunner::WindowProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg != kRunTasksMessage) return DefWindowProcW(hwnd, msg, wparam, lparam);
  auto* runner = reinterpret_cast<UiTaskRunner*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!runner) return 0;
  std::vector<std::function<void()>> pending;
  {
    std::lock_guard<std::mutex> lock(runner->mutex_);
    pending.swap(runner->tasks_);
  }
  for (auto& task : pending) task();
  return 0;
}
