// 上游诊断帧净化规则单测(实测样本:[ede_diagnostic] result_type=user
// last_content_type=n/a stop_reason=null —— 原样透传成用户红色错误行,天书)。
import { describe, expect, it } from 'vitest';
import { isInternalDiagnostic, sanitizeCliError } from '../src/protocol/cli-error-sanitize.js';

describe('cli-error-sanitize', () => {
  it('识别上游诊断帧', () => {
    expect(isInternalDiagnostic('[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null')).toBe(true);
    expect(isInternalDiagnostic('... last_content_type=n/a ...')).toBe(true);
    expect(isInternalDiagnostic('... stop_reason=null')).toBe(true);
  });

  it('超长内部堆栈也算天书(>400 字符)', () => {
    expect(isInternalDiagnostic('x'.repeat(401))).toBe(true);
    expect(isInternalDiagnostic('命令失败: file not found')).toBe(false);
  });

  it('普通错误原样透传,诊断帧换可读文案', () => {
    expect(sanitizeCliError('命令失败: file not found')).toBe('命令失败: file not found');
    expect(sanitizeCliError('[ede_diagnostic] result_type=user')).toBe(
      '上游模型响应异常,本轮已中断;请重发(持续出现请检查模型路由/网络)',
    );
  });
});
