import 'package:flutter/material.dart';

/// Контроллер с плавной прокруткой колесом мыши: вместо мгновенного скачка
/// каждое деление колеса анимируется, а быстрые прокрутки подряд накапливаются.
class SmoothScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SmoothScrollPosition(
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  static const _duration = Duration(milliseconds: 320);
  double? _target;

  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    // Если анимация ещё идёт — прибавляем к её цели, чтобы прокрутка не «тормозила».
    final base = _target != null && isScrollingNotifier.value ? _target! : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    _target = target;
    animateTo(target, duration: _duration, curve: Curves.easeOutCubic);
  }
}

/// Создаёт и освобождает [SmoothScrollController] для прокручиваемого содержимого.
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});
  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// Отдельный контроллер плавной прокрутки для раздела: списки внутри берут его через primary: true.
class SmoothPage extends StatelessWidget {
  const SmoothPage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SmoothScroll(
        builder: (context, controller) => PrimaryScrollController(controller: controller, child: child),
      );
}