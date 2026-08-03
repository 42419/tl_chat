import 'package:flutter/material.dart';

/// Phase 2.1 typing indicator subtitle for the chat header.
///
/// Shows a small three-dot pulse animation + 「正在输入…」 (1:1) or
/// 「name 正在输入…」 (room, when only one is typing) / 「N 人正在输入…」
/// (room, multiple). The pulse is a cheap infinite Tween — no extra deps.
class TypingSubtitle extends StatefulWidget {
  const TypingSubtitle({
    super.key,
    required this.isRoom,
    required this.senders,
    required this.onlineColor,
    required this.subtextColor,
    required this.baseStyle,
  });

  final bool isRoom;
  final List<String> senders;
  final Color onlineColor;
  final Color subtextColor;
  final TextStyle baseStyle;

  @override
  State<TypingSubtitle> createState() => _TypingSubtitleState();
}

class _TypingSubtitleState extends State<TypingSubtitle>
    with TickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isRoom
        ? (widget.senders.length == 1
              ? '${widget.senders.first} 正在输入…'
              : widget.senders.isEmpty
              ? '正在输入…'
              : '${widget.senders.length} 人正在输入…')
        : '正在输入…';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Three pulsing dots — staggered by 0.33 phase each.
        SizedBox(
          width: 22,
          height: 12,
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: List.generate(3, (i) {
                  final phase = (_ctrl.value + i / 3) % 1.0;
                  // 0..0.5 ramp up, 0.5..1 ramp down — a sine-ish pulse.
                  final scale = 0.6 + 0.4 * (1 - (2 * phase - 1).abs());
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Transform.translate(
                      offset: Offset(0, -1 * (1 - scale)),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: widget.onlineColor.withValues(alpha: scale),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.baseStyle.copyWith(
              fontSize: 12,
              color: widget.onlineColor,
            ),
          ),
        ),
      ],
    );
  }
}
