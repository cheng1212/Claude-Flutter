// 「选择文字」二级页:全 App 唯一保留 SelectableText 的地方。
//
// 为什么不在聊天列表里直接选中:列表是回收的(builder 复用 + 流式每秒重排几十次),
// 在列表里选中随时会被重建冲掉(flutter#124787),用户体验就是「选中了又没了」。
// 这个弹层不在列表里,选中稳定;代价是长按要先经菜单一步,换来的是长按手势
// 能统一交给行级菜单(见 chat_page._list 的说明)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'toast.dart';

/// 打开「选择文字」弹层。
/// [text] 走纯文本口径(见 row_actions.selectableTextFor),贴出去不带 markdown 标记。
Future<void> showTextSelectSheet(
  BuildContext context, {
  required String title,
  required String text,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ZT.bg,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
      side: BorderSide(color: ZT.edge),
    ),
    builder: (_) => _TextSelectSheet(title: title, text: text),
  );
}

class _TextSelectSheet extends StatelessWidget {
  final String title;
  final String text;

  const _TextSelectSheet({required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.66;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: ShapeDecoration(
                  color: ZT.surfaceHi,
                  shape: StadiumBorder(side: ZT.inkSide(w: 1)),
                ),
                child: Text(title,
                    style: TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w800, color: ZT.inkSoft)),
              ),
              const Spacer(),
              _CopyAllButton(text: text),
              const SizedBox(width: 4),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.close_rounded, size: 18, color: ZT.inkSoft),
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 2),
            Text('长按文字拖选,或点右上角复制全部',
                style: TextStyle(fontSize: 11, color: ZT.inkFaint)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: ShapeDecoration(
                  color: ZT.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(ZT.radius),
                    side: ZT.inkSide(w: 1),
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: ZT.ink),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「复制全部」:点了给个 ✓ 反馈,但**不关页面** —— 用户可能还想挑一段。
class _CopyAllButton extends StatefulWidget {
  final String text;

  const _CopyAllButton({required this.text});

  @override
  State<_CopyAllButton> createState() => _CopyAllButtonState();
}

class _CopyAllButtonState extends State<_CopyAllButton> {
  bool _copied = false;
  Timer? _resetTimer;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    showToast(context, '已复制');
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _copy,
      icon: Icon(_copied ? Icons.check_rounded : Icons.content_copy_rounded,
          size: 15, color: _copied ? ZT.aqua : ZT.primaryDeep),
      label: Text(_copied ? '已复制' : '复制全部',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w800,
              color: _copied ? ZT.aqua : ZT.primaryDeep)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
