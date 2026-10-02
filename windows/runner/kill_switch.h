#ifndef RUNNER_KILL_SWITCH_H_
#define RUNNER_KILL_SWITCH_H_

#include <string>
#include <vector>

// Kill Switch: фильтры Windows (WFP), которые не выпускают трафик мимо VPN.
// Управляется из Dart через канал "skipit/killswitch" (lib/core/kill_switch.dart).
//
// Пока фильтры стоят, в сеть могут выходить только:
//  - ядра VPN (|apps| — полные пути к их exe);
//  - соединения через адаптер VPN (их локальный адрес — |tun_v4| или |tun_v6|);
//  - соединения внутри компьютера и с локальной сетью (кроме DNS — имена сайтов не должны уйти мимо VPN).
// Всё остальное блокируется. Если адаптер пропал (ядро упало), программы остаются без интернета,
// а не идут в сеть напрямую.
//
// Фильтры живут, пока открыт сеанс WFP: при выходе программы, даже аварийном, Windows убирает их сама.
// Возвращает пустую строку или текст ошибки (тогда фильтры не поставлены).
std::wstring KillSwitchEngage(const std::vector<std::wstring>& apps, const std::wstring& tun_v4,
                              const std::wstring& tun_v6);

// Снимает фильтры. Безопасно вызывать, когда они не стоят.
void KillSwitchRelease();

#endif  // RUNNER_KILL_SWITCH_H_
