#ifndef RUNNER_TRAY_MENU_H_
#define RUNNER_TRAY_MENU_H_

#include <windows.h>

#include <string>
#include <vector>

// Сервер в меню значка: название и картинка флага (путь к PNG; пусто — флага нет).
struct TrayMenuServer {
  std::wstring name;
  std::wstring flag;
};

// Что показать в меню значка в трее. Подписи и состояние приходят из Dart (lib/core/tray.dart).
struct TrayMenuModel {
  std::wstring title = L"SkipIt";
  // «Подключено», «Не подключено»…
  std::wstring status;
  // Название выбранного сервера.
  std::wstring server;
  std::wstring label_open = L"Open";
  std::wstring label_toggle = L"Connect";
  std::wstring label_exit = L"Exit";
  std::wstring label_mode = L"Mode";
  std::wstring label_servers = L"Server";
  // 0 — не подключено, 1 — идёт подключение или отключение, 2 — подключено.
  int state = 0;
  // Тёмная или светлая тема программы.
  bool dark = true;
  // Режимы подключения (подписи) и номер выбранного.
  std::vector<std::wstring> modes;
  int mode = -1;
  // Серверы и номер выбранного.
  std::vector<TrayMenuServer> servers;
  int selected_server = -1;
};

// Команды, которые меню отправляет владельцу. Режим и сервер — это база плюс номер пункта.
struct TrayMenuCommands {
  UINT toggle;
  UINT open;
  UINT exit;
  UINT mode_base;
  UINT server_base;
};

// Показывает меню в стиле программы у точки |pt| (обычно — у курсора над значком в трее).
// Выбранный пункт приходит окну |owner| сообщением |message|, команда — в wParam.
// Меню закрывается само при клике мимо и по Esc.
void ShowTrayMenu(HWND owner, UINT message, POINT pt, const TrayMenuModel& model,
                  const TrayMenuCommands& commands);

#endif  // RUNNER_TRAY_MENU_H_
