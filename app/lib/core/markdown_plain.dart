// Markdown → 纯文本:复制助手消息时贴进文档/聊天框,不留 **、#、` 这些标记。
//
// 自己写而不引包:规则只需覆盖本 App 会渲染的子集,且有一条硬约束 ——
// **围栏代码块内的内容必须原样保留**(`#` 在 shell 里是注释、`**` 在代码里是乘方),
// 无脑全局正则会把代码改烂,所以走行级状态机。
//
// 刻意不剥单星号/单下划线斜体:`2 * 3 * 4`、`snake_case` 这类内容太常见,
// 剥了就是把正文改错 —— 宁可留标记,不可改内容。

/// 行首围栏识别,规则与 rows.dart 的 balanceFences 一致(3 个以上 ``` 或 ~~~)。
final _fenceRe = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

/// 水平分割线:整行只有 3 个以上的 -、* 或 _(可夹空格)。
final _hrRe = RegExp(r'^\s*([-*_])\s*(?:\1\s*){2,}$');

final _headingRe = RegExp(r'^\s{0,3}#{1,6}\s+');
final _quoteRe = RegExp(r'^\s{0,3}>\s?');
final _bulletRe = RegExp(r'^(\s*)[-*+]\s+');
final _imageRe = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _linkRe = RegExp(r'\[([^\]]*)\]\([^)]*\)');
final _codeSpanRe = RegExp(r'(`+)([^`]*)`+');
final _boldStarRe = RegExp(r'\*\*([^*]+)\*\*');
final _boldUnderscoreRe = RegExp(r'__([^_]+)__');
final _strikeRe = RegExp(r'~~([^~]+)~~');

/// Markdown 源码 → 便于粘贴的纯文本。
///
/// 保留:正文、代码块正文、有序列表编号、表格行(原样,不拆)。
/// 剥离:围栏标记、标题 `#`、引用 `> `、无序列表标记(转 `• `)、加粗/删除线、
/// 行内 code 反引号、链接与图片语法(只留可见文字)。
String markdownToPlain(String src) {
  final out = <String>[];
  String? openFence; // 开栏字符(` 或 ~)
  var openLen = 0;

  for (final raw in src.split('\n')) {
    final line = raw.replaceAll('\r', '').trimRight();
    final m = _fenceRe.firstMatch(line);
    final marker = m?.group(1);
    final ch = marker?[0];

    if (openFence != null) {
      // 栏内:同字符且不短于开栏 → 闭合行(丢弃);否则整行原样保留
      if (ch != null && ch == openFence && marker!.length >= openLen) {
        openFence = null;
      } else {
        out.add(line);
      }
      continue;
    }
    if (marker != null) {
      openFence = ch;
      openLen = marker.length;
      continue; // 开栏行本身丢弃(语言标签不复制)
    }
    if (_hrRe.hasMatch(line)) continue; // 分割线整行丢弃

    out.add(_inline(line));
  }

  // 折叠 3 行以上空行,并去掉首尾空白
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// 单行行内标记剥离(仅正文行;栏内代码不走这里)。
String _inline(String line) {
  var s = line;
  s = s.replaceFirst(_headingRe, '');
  s = s.replaceFirst(_quoteRe, '');
  s = s.replaceFirstMapped(_bulletRe, (m) => '${m[1]}• ');
  s = s.replaceAllMapped(_imageRe, (m) => m[1]!);
  s = s.replaceAllMapped(_linkRe, (m) => m[1]!);
  s = s.replaceAllMapped(_codeSpanRe, (m) => m[2]!);
  s = s.replaceAllMapped(_boldStarRe, (m) => m[1]!);
  s = s.replaceAllMapped(_boldUnderscoreRe, (m) => m[1]!);
  s = s.replaceAllMapped(_strikeRe, (m) => m[1]!);
  return s;
}
