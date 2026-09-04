import 'package:flutter/material.dart';

/// Slide-to-confirm control for clock-in / clock-out.
///
/// The knob tracks the finger. Releasing past [threshold] animates the knob to
/// the far end and fires [onConfirmed] once; releasing early springs it back.
/// Direction follows state: checked-out slides right to clock in, checked-in
/// slides left to clock out. Every completed gesture reports exactly once, so
/// callers do not need re-entrancy guards against per-frame drag events.
class SlideToClockButton extends StatefulWidget {
  const SlideToClockButton({
    super.key,
    required this.checkedIn,
    required this.label,
    required this.onConfirmed,
    this.enabled = true,
    this.threshold = 0.6,
  });

  /// Current clock state. Drives colour, arrow, and slide direction.
  final bool checkedIn;

  /// Text shown in the track, e.g. "Swipe to Check-In".
  final String label;

  /// Called once per completed slide. `checkingIn` is the action requested.
  final Future<void> Function({required bool checkingIn}) onConfirmed;

  /// Ignore input while an action is in flight.
  final bool enabled;

  /// Fraction of the track the knob must pass before release confirms.
  final double threshold;

  @override
  State<SlideToClockButton> createState() => _SlideToClockButtonState();
}

class _SlideToClockButtonState extends State<SlideToClockButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() {}));

  /// 0 = knob at rest, 1 = knob at the far end. Always measured along the
  /// slide direction, so it reads the same whether sliding left or right.
  double _progress = 0;
  bool _dragging = false;

  bool get _slidesRight => !widget.checkedIn;

  @override
  void didUpdateWidget(covariant SlideToClockButton old) {
    super.didUpdateWidget(old);
    // State flipped after a successful action: reset for the new direction.
    if (old.checkedIn != widget.checkedIn) {
      _controller.stop();
      _progress = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails d) {
    if (!widget.enabled) return;
    _controller.stop();
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails d, double travel) {
    if (!_dragging || travel <= 0) return;
    final delta = (_slidesRight ? d.delta.dx : -d.delta.dx) / travel;
    setState(() => _progress = (_progress + delta).clamp(0.0, 1.0));
  }

  Future<void> _onDragEnd(DragEndDetails d) async {
    if (!_dragging) return;
    _dragging = false;

    if (_progress >= widget.threshold) {
      await _animateTo(1.0);
      if (!mounted) return;
      await widget.onConfirmed(checkingIn: !widget.checkedIn);
      if (!mounted) return;
      // If the action failed the state did not flip; glide back to rest.
      if (_progress == 1.0) await _animateTo(0.0);
    } else {
      await _animateTo(0.0);
    }
  }

  Future<void> _animateTo(double target) {
    final from = _progress;
    final tween = Tween<double>(begin: from, end: target);
    final anim = tween.animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    void tick() => _progress = anim.value;
    anim.addListener(tick);
    return _controller.forward(from: 0).whenComplete(() {
      anim.removeListener(tick);
      _progress = target;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final trackColor = widget.checkedIn ? Colors.red : Colors.green;
    final knobWidth = size.width * 0.12;
    final trackHeight = size.height * 0.07;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const pad = 8.0;
          final travel = constraints.maxWidth - knobWidth - pad * 2;
          final offset = _progress * travel;
          final knobLeft = _slidesRight ? pad + offset : pad + travel - offset;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: (d) => _onDragUpdate(d, travel),
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: () {
              _dragging = false;
              _animateTo(0.0);
            },
            child: Container(
              height: trackHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.0),
                color: widget.enabled ? trackColor : trackColor.withOpacity(0.6),
              ),
              child: Stack(
                children: [
                  // Label fades as the knob covers it.
                  Center(
                    child: Opacity(
                      opacity: (1 - _progress * 1.4).clamp(0.0, 1.0),
                      child: Text(
                        widget.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: knobLeft,
                    top: pad,
                    bottom: pad,
                    width: knobWidth,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10.0),
                        color: Colors.white,
                      ),
                      child: Icon(
                        _slidesRight ? Icons.arrow_forward : Icons.arrow_back,
                        color: trackColor,
                        size: 30.0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
