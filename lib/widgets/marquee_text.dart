import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  const MarqueeText({
    required this.text,
    required this.style,
    required this.isRunning,
    this.pixelsPerSecond = 70,
    this.gap = 96,
    super.key,
  });

  final String text;
  final TextStyle style;
  final bool isRunning;
  final double pixelsPerSecond;
  final double gap;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Duration? _configuredDuration;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller.stop();
      _controller.value = _controller.lowerBound;
      _configuredDuration = null;
    }
    if (!widget.isRunning) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: direction,
      textScaler: textScaler,
    )..layout();
    final textWidth = painter.width;
    painter.dispose();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        if (textWidth <= viewportWidth || viewportWidth <= 0) {
          if (_controller.isAnimating) _controller.stop();
          return Center(
            child: Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          );
        }

        final cycleWidth = textWidth + widget.gap;
        final duration = Duration(
          milliseconds: (cycleWidth / widget.pixelsPerSecond * 1000)
              .round()
              .clamp(1000, 120000)
              .toInt(),
        );
        if (_configuredDuration != duration) {
          _configuredDuration = duration;
          _controller.duration = duration;
        }
        if (widget.isRunning && !_controller.isAnimating) {
          // repeat() needs a duration. Set it above before starting, including
          // when a short message (which needed no animation) is replaced by a
          // long queued message.
          _controller.repeat();
        } else if (!widget.isRunning && _controller.isAnimating) {
          _controller.stop();
        }

        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(-cycleWidth * _controller.value, 0),
              child: child,
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: cycleWidth * 2,
              maxWidth: cycleWidth * 2,
              child: Semantics(
                label: widget.text,
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _messageText(),
                      SizedBox(width: widget.gap),
                      _messageText(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _messageText() => Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        softWrap: false,
      );
}
