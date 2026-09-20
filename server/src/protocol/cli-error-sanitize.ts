// 上游/SDK 异常消息的净化规则(T4 后续加固,2026-09-14):
// CLI 进程从上游模型 API 收到的内部诊断帧(实测:[ede_diagnostic] result_type=user
// last_content_type=n/a stop_reason=null)原本被原样透传成用户可见的红色错误行 ——
// 天书且无行动指引。此类帧识别为「上游流异常」,对用户换成可读提示,原文落服务端日志。
// 纯函数,可单测。

/** 判定是否内部诊断/天书消息(不该直接给用户看)。 */
export function isInternalDiagnostic(message: string): boolean {
  return (
    /_diagnostic\]/.test(message) ||
    /stop_reason=\S*\b/.test(message) ||
    /last_content_type=/.test(message) ||
    message.length > 400
  );
}

/** 净化后的用户文案。 */
export function sanitizeCliError(message: string): string {
  if (isInternalDiagnostic(message)) {
    return '上游模型响应异常,本轮已中断;请重发(持续出现请检查模型路由/网络)';
  }
  return message;
}
