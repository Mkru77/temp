#include "flutter_window.h"

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kStartupKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kStartupValue[] = L"TempSensorWidget";

bool IsStartupEnabled(bool* enabled, std::wstring* error) {
  HKEY key = nullptr;
  LSTATUS status =
      RegOpenKeyExW(HKEY_CURRENT_USER, kStartupKey, 0, KEY_QUERY_VALUE, &key);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
    *enabled = false;
    return true;
  }
  if (status != ERROR_SUCCESS) {
    *error = L"Nie można odczytać ustawienia autostartu Windows.";
    return false;
  }

  status = RegQueryValueExW(key, kStartupValue, nullptr, nullptr, nullptr,
                            nullptr);
  RegCloseKey(key);
  if (status == ERROR_FILE_NOT_FOUND) {
    *enabled = false;
    return true;
  }
  if (status != ERROR_SUCCESS) {
    *error = L"Nie można odczytać ustawienia autostartu Windows.";
    return false;
  }

  *enabled = true;
  return true;
}

std::string ToUtf8(const std::wstring& value) {
  const int length = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (length <= 0) {
    return "Windows startup setting could not be updated.";
  }

  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), length,
                      nullptr, nullptr);
  return result;
}

bool SetStartupEnabled(bool enabled, std::wstring* error) {
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(
      HKEY_CURRENT_USER, kStartupKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
      &key, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = L"Nie można otworzyć klucza autostartu Windows.";
    return false;
  }

  if (enabled) {
    std::vector<wchar_t> executable_path(32768);
    const DWORD path_length = GetModuleFileNameW(
        nullptr, executable_path.data(),
        static_cast<DWORD>(executable_path.size()));
    if (path_length == 0 || path_length >= executable_path.size()) {
      RegCloseKey(key);
      *error = L"Nie można ustalić ścieżki aplikacji.";
      return false;
    }

    const std::wstring command =
        L"\"" + std::wstring(executable_path.data(), path_length) +
        L"\" --widget";
    status = RegSetValueExW(
        key, kStartupValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, kStartupValue);
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }

  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    *error = L"Windows nie pozwolił zmienić wpisu autostartu.";
    return false;
  }
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "temp/windows",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getStartupEnabled") {
          bool enabled = false;
          std::wstring error;
          if (!IsStartupEnabled(&enabled, &error)) {
            result->Error("startup_error", ToUtf8(error));
            return;
          }
          result->Success(flutter::EncodableValue(enabled));
          return;
        }

        if (call.method_name() == "setStartupEnabled") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (!enabled) {
            result->Error("invalid_argument", "Expected a boolean value.");
            return;
          }
          std::wstring error;
          if (!SetStartupEnabled(*enabled, &error)) {
            result->Error("startup_error", ToUtf8(error));
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "setWidgetMode") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (!enabled) {
            result->Error("invalid_argument", "Expected a boolean value.");
            return;
          }
          if (!SetWidgetMode(*enabled)) {
            result->Error("window_error", "Could not resize the window.");
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "closeWindow") {
          if (!PostMessage(GetHandle(), WM_CLOSE, 0, 0)) {
            result->Error("window_error", "Could not close the window.");
            return;
          }
          result->Success();
          return;
        }

        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  method_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
