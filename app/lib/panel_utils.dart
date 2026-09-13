// 面板派生:子代理(Task/Agent 发起)与后台任务(Bash run_in_background)聚合。
// 纯函数,操作 reducer 的 ChatRow,可单测。
import 'state/reducer.dart';

class SubagentInfo {
  final String toolId;
  final String description;
  final int activityCount; // 该子代理名下的工具活动数
  final bool done;

  /// 模型**请求**用的模型(Agent/Task 的 input.model)。空 = 没指定,继承主模型。
  /// 用户最关心的一条:Claude 有时会自己挑贵的模型,这个字段让"挑了什么"可见;
  /// server 侧 PreToolUse hook 会把它强制改写成主会话模型,所以实际执行的一定是会话模型。
  final String requestedModel;

  /// 子代理类型(Agent/Task 的 subagent_type),如 general-purpose / Explore。
  final String agentType;

  const SubagentInfo({
    required this.toolId,
    required this.description,
    required this.activityCount,
    required this.done,
    this.requestedModel = '',
    this.agentType = '',
  });
}

class BackgroundInfo {
  final String toolId;
  final String command;
  final bool running;
  final String outputTail;

  const BackgroundInfo({
    required this.toolId,
    required this.command,
    required this.running,
    required this.outputTail,
  });
}

/// 子代理聚合:Task/Agent 工具行即子代理本体;其余工具按 parentToolUseId 归入其名下。
List<SubagentInfo> deriveSubagents(List<ChatRow> rows) {
  final agents = <String, SubagentInfo>{};
  final activity = <String, int>{};

  for (final r in rows) {
    if (r is! ToolRow) continue;
    if (r.parentToolUseId != null) {
      activity[r.parentToolUseId!] = (activity[r.parentToolUseId!] ?? 0) + 1;
    }
    final n = r.toolName.toLowerCase();
    if (n == 'task' || n == 'agent') {
      final input = r.toolInput;
      final desc = (input['description'] ?? input['prompt'] ?? input['text'] ?? '').toString().trim();
      agents[r.toolId] = SubagentInfo(
        toolId: r.toolId,
        description: desc.isEmpty ? '子代理' : desc,
        activityCount: 0,
        done: r.result != null,
        requestedModel: '${input['model'] ?? ''}'.trim(),
        agentType: '${input['subagent_type'] ?? input['subagentType'] ?? ''}'.trim(),
      );
    }
  }
  // 活动计数合并(第二遍:agents 定义可能在嵌套活动之后出现)
  for (final r in rows) {
    if (r is! ToolRow) continue;
    final p = r.parentToolUseId;
    if (p != null && agents.containsKey(p)) {
      agents[p] = SubagentInfo(
        toolId: agents[p]!.toolId,
        description: agents[p]!.description,
        activityCount: activity[p] ?? 0,
        done: agents[p]!.done,
        requestedModel: agents[p]!.requestedModel,
        agentType: agents[p]!.agentType,
      );
    }
  }
  return agents.values.toList();
}

/// 后台任务聚合:Bash(run_in_background=true);结果到达即完成,输出取其结果。
List<BackgroundInfo> deriveBackgrounds(List<ChatRow> rows) {
  final out = <BackgroundInfo>[];
  for (final r in rows) {
    if (r is! ToolRow) continue;
    if (r.toolName.toLowerCase() != 'bash') continue;
    if (r.toolInput['run_in_background'] != true) continue;
    out.add(BackgroundInfo(
      toolId: r.toolId,
      command: '${r.toolInput['command'] ?? ''}',
      running: r.result == null,
      outputTail: r.result?.content ?? '',
    ));
  }
  return out;
}

/// 跨会话引用:把源会话导出的 markdown 压缩成可注入的上下文消息。
/// 超长时截头留尾(head/tail 字符数),中间用省略标记衔接。
String buildReferenceMessage({
  required String fromTitle,
  required String markdown,
  int head = 4000,
  int tail = 8000,
}) {
  String body;
  if (markdown.length <= head + tail) {
    body = markdown;
  } else {
    body = '${markdown.substring(0, head)}'
        '\n\n……(中间 ${markdown.length - head - tail} 字符省略)……\n\n'
        '${markdown.substring(markdown.length - tail)}';
  }
  return '【引用会话「$fromTitle」的近期上下文】\n'
      '以下内容来自另一个会话的导出,请把它当作你已有的记忆,并结合它继续帮我:\n\n'
      '$body';
}
