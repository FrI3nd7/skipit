import 'package:flutter/material.dart';

import 'theme.dart';

/// Отслеживает наведение мыши и перестраивает содержимое.
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.cursor = SystemMouseCursors.click, this.enabled = true});
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final bool enabled;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.enabled ? widget.cursor : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: widget.builder(context, widget.enabled && _hover),
      );
}

/// Знак приложения: два скруглённых треугольника «перемотки».
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 32, this.opacities = const (1.0, 1.0), this.muted = false, this.white = false});
  final double size;

  /// Прозрачность левого и правого треугольника — для анимации при подключении.
  final (double, double) opacities;
  final bool muted;
  final bool white;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size * 0.72,
        child: CustomPaint(painter: _MarkPainter(opacities, muted, white)),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.opacities, this.muted, this.white);
  final (double, double) opacities;
  final bool muted;
  final bool white;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = h * 0.12;
    final Gradient gradient = white
        ? const LinearGradient(colors: [Colors.white, Colors.white])
        : muted
            ? LinearGradient(colors: [C.palette.markMuted, C.palette.markMuted])
            : C.gradient;

    Path tri(double x0, double tw) => Path()
      ..moveTo(x0 + r, r)
      ..lineTo(x0 + tw - r, h / 2)
      ..lineTo(x0 + r, h - r)
      ..close();

    void drawTri(Path p) {
      final shader = gradient.createShader(Offset.zero & size);
      canvas.drawPath(p, Paint()..shader = shader);
      canvas.drawPath(
          p,
          Paint()
            ..shader = shader
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..strokeJoin = StrokeJoin.round);
    }

    // Два одинаковых треугольника с небольшим зазором, без выемки (на крупной кнопке она выглядела как кружок).
    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: opacities.$1));
    drawTri(tri(0, w * 0.48));
    canvas.restore();

    canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: opacities.$2));
    drawTri(tri(w * 0.52, w * 0.48));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) =>
      old.opacities != opacities || old.muted != muted || old.white != white;
}

/// Значок приложения — та же картинка, что у иконки exe (assets/icon.png из tools/make_icon.ps1).
class AppBadge extends StatelessWidget {
  const AppBadge({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/icon.png', width: size, height: size, filterQuality: FilterQuality.medium);
}

/// Выпадающий список в общем стиле: скруглённая рамка, подсветка при наведении, без «залипающего» фокуса.
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expand = false,
    this.leading,
    this.height,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final bool expand;
  final Widget? leading;
  final double? height;

  @override
  Widget build(BuildContext context) => Hover(
        builder: (context, hovered) => AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: height,
          padding: const EdgeInsets.only(left: 14, right: 8),
          decoration: BoxDecoration(
            color: hovered ? C.orange.withValues(alpha: 0.08) : (height != null ? C.surface : Colors.transparent),
            borderRadius: BorderRadius.circular(height != null ? 18 : 12),
            border: Border.all(color: hovered ? C.orange.withValues(alpha: 0.7) : C.border),
          ),
          child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Flexible(
              fit: expand ? FlexFit.tight : FlexFit.loose,
              child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: expand,
              focusColor: Colors.transparent,
              dropdownColor: C.surface2,
              borderRadius: BorderRadius.circular(12),
              icon: Icon(Icons.expand_more_rounded, color: C.muted),
              style: TextStyle(color: C.text, fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'Segoe UI'),
              items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) {
                if (v != null) onChanged(v);
                // Снимаем фокус, иначе Flutter оставляет подсветку после выбора.
                FocusManager.instance.primaryFocus?.unfocus();
              },
            ),
          ),
            ),
          ]),
        ),
      );
}
/// Панель с тонкой рамкой. Если задан onTap — подсвечивается при наведении.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.glow = false, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Hover(
        enabled: onTap != null,
        builder: (context, hovered) => GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: padding,
            decoration: BoxDecoration(
              color: hovered ? C.surface2 : C.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: glow
                    ? C.orange.withValues(alpha: 0.6)
                    : (hovered ? C.orange.withValues(alpha: 0.35) : C.border),
              ),
              boxShadow: glow ? [BoxShadow(color: C.orange.withValues(alpha: 0.16), blurRadius: 24)] : null,
            ),
            child: child,
          ),
        ),
      );
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const [], this.below});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// Дополнительная строка под заголовком (например, вкладки раздела).
  final Widget? below;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: TextStyle(color: C.muted, fontSize: 13)),
                ],
                if (below != null) ...[const SizedBox(height: 14), below!],
              ]),
            ),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      );
}

/// Кнопка с оранжевым градиентом; при наведении светится ярче.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, this.icon, this.onPressed});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Hover(
      enabled: enabled,
      builder: (context, hovered) => Opacity(
        opacity: enabled ? 1 : 0.5,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            gradient: hovered
                ? const LinearGradient(colors: [Color(0xFFFFAE5C), Color(0xFFFF7033)])
                : C.gradient,
            borderRadius: BorderRadius.circular(12),
            boxShadow: enabled
                ? [BoxShadow(color: C.orange.withValues(alpha: hovered ? 0.55 : 0.3), blurRadius: hovered ? 22 : 14)]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: Colors.white), const SizedBox(width: 8)],
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Контурная кнопка; при наведении — оранжевая рамка и лёгкая заливка.
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.label, this.icon, this.onPressed, this.busy = false});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: busy ? null : onPressed,
        style: ButtonStyle(
          side: WidgetStateProperty.resolveWith((s) => BorderSide(
                color: s.contains(WidgetState.hovered) ? C.orange.withValues(alpha: 0.7) : C.border,
              )),
          backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.hovered) ? C.orange.withValues(alpha: 0.08) : Colors.transparent),
          overlayColor: WidgetStateProperty.all(C.orange.withValues(alpha: 0.08)),
        ),
        icon: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: C.orange))
            : Icon(icon ?? Icons.circle, size: 18),
        label: Text(label),
      );
}

/// Кнопка подключения: плитка со знаком ▶▶. Кликабельна только сама плитка.
/// При подключении знак «перематывается», при активном соединении плитка светится.
class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key, required this.connected, required this.busy, required this.onTap});
  final bool connected;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  bool _hover = false;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 200.0;
    const radius = 50.0;
    final active = widget.connected;
    final lit = active || widget.busy || _hover;
    return AnimatedScale(
      scale: _hover ? 1.03 : 1,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: ClipRRect(
        // Клип ограничивает и зону нажатия: углы плитки не кликаются.
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                // Ровная заливка: тёмный градиент на экране ложился заметными полосами.
                color: active ? C.palette.tileActiveTop : C.palette.tileTop,
                border: Border.all(
                  color: active ? C.orange : (lit ? C.orange.withValues(alpha: 0.55) : C.border),
                  width: 2,
                ),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: AnimatedBuilder(
                    animation: _anim,
                    builder: (_, __) {
                      var ops = (1.0, 1.0);
                      if (widget.busy) {
                        final t = _anim.value;
                        ops = (t < 0.5 ? 1.0 : 0.25, t < 0.5 ? 0.25 : 1.0);
                      }
                      return AppMark(size: 104, opacities: ops, muted: !lit);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Свечение вокруг кнопки подключения (рисуется снаружи клипа).
class ConnectGlow extends StatelessWidget {
  const ConnectGlow({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(50),
          boxShadow: [
            // Большая тёмная тень на тёмном фоне тоже давала полосы — оставлено только свечение при подключении.
            if (active) BoxShadow(color: C.orange.withValues(alpha: 0.4), blurRadius: 60, spreadRadius: 2),
          ],
        ),
        child: child,
      );
}

class DelayBadge extends StatelessWidget {
  const DelayBadge(this.ms, {super.key, this.testing = false});
  final int? ms;
  final bool testing;

  @override
  Widget build(BuildContext context) {
    final text = ms == null ? (testing ? '…' : '—') : (ms! < 0 ? 'нет' : '$ms мс');
    final color = C.delay(ms);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, Color? color}) : _color = color;
  final String text;
  final Color? _color;
  Color get color => _color ?? C.muted;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      );
}

/// Сегментированный переключатель; невыбранные пункты подсвечиваются при наведении.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => FittedBox(
        // В узком месте переключатель ужимается целиком, а не вылезает за край.
        fit: BoxFit.scaleDown,
        child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: C.surface2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in items.entries)
              Hover(
                builder: (context, hovered) {
                  final selected = e.key == value;
                  return GestureDetector(
                    onTap: () => onChanged(e.key),
                    // Выбор переключается мгновенно: фон и цвет текста меняются в один кадр.
                    // Плавный переход на светлом фоне давал «грязные» промежуточные цвета.
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        gradient: selected ? C.gradient : null,
                        color: !selected && hovered ? C.hover : null,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(e.value,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: selected ? Colors.white : (hovered ? C.text : C.muted),
                          )),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
      );
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
  int maxLines = 1,
  String ok = 'Готово',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: maxLines,
          minLines: 1,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        GradientButton(label: ok, onPressed: () => Navigator.pop(ctx, ctrl.text)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String text, {String ok = 'Удалить'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          GradientButton(label: ok, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    ) ??
    false;
