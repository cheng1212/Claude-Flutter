// 居中 Toast:底部 SnackBar 会盖住快捷条和输入框挡操作,改从窗口中央浮出,
// 2.2 秒自动淡出;带动作时整条可点。纯提示不挡手势(IgnorePointer)。
import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

void showToast(BuildContext context, String msg, {String? actionLabel, VoidCallback? onAction}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  var removed = false;
  void close() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => Positioned.fill(
      child: IgnorePointer(
        // 带动作的 Toast 要能点按钮;纯提示完全不挡操作
        ignoring: actionLabel == null,
        child: _CenterToast(
          msg: msg,
          actionLabel: actionLabel,
          onAction: () {
            close();
            onAction?.call();
          },
          onClose: close,
        ),
      ),
    ),
  );
  overlay.insert(entry);
}

class _CenterToast extends StatefulWidget {
  final String msg;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;

  const _CenterToast({
    required this.msg,
    required this.onClose,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_CenterToast> createState() => _CenterToastState();
}

class _CenterToastState extends State<_CenterToast> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _visible = true;
    _timer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 240),
      child: Padding(
        // 抬到键盘上方一点:居中偏上,别跟输入法打架
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom * 0.25),
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(ZT.radius),
              onTap: widget.actionLabel == null ? null : widget.onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: ShapeDecoration(
                  color: ZT.ink.withValues(alpha: 0.92),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ZT.radius),
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(
                      widget.msg,
                      style: TextStyle(fontSize: 12.5, color: ZT.surface, height: 1.4),
                    ),
                  ),
                  if (widget.actionLabel != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      widget.actionLabel!,
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w800, color: ZT.lemon),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
