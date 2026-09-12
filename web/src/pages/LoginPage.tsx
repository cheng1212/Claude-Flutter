import { useRef, useState } from 'react';
import { DEFAULT_BASE_URL, DEFAULT_TOKEN } from '../lib/store';

/**
 * 登录页:填服务器地址 + 访问令牌。地址缺 scheme 自动补 http://。
 * 非受控输入:提交时直接读 DOM 值——浏览器自动填充/IME 不触发 React onChange
 * 时受控方案会让按钮永久禁用("点不了"),这里按钮永远可点,所见即所提交。
 */
export function LoginPage({ initial, onLogin }: {
  initial?: { baseUrl: string; token: string };
  onLogin: (baseUrl: string, token: string) => void;
}) {
  const addrRef = useRef<HTMLInputElement>(null);
  const tokRef = useRef<HTMLInputElement>(null);
  const [hint, setHint] = useState<string | null>(null);

  const go = (e: React.FormEvent) => {
    e.preventDefault();
    const b = (addrRef.current?.value ?? '').trim();
    const t = (tokRef.current?.value ?? '').trim();
    if (!b || !t) {
      setHint('请填写服务器地址和访问令牌(两者都要填)');
      return;
    }
    setHint(null);
    onLogin(/^[a-z][a-z0-9+.-]*:\/\//i.test(b) ? b : `http://${b}`, t);
  };

  return (
    <div className="login">
      <form className="login__panel deco-corners" onSubmit={go}>
        <div className="login__brand">
          <span className="login__glyph">◆</span>
          <h1 className="login__title">zCode</h1>
          <p className="login__sub">黑金终端 · 连上你电脑上的 Claude Code</p>
        </div>
        <label className="field">
          <span className="field__label">服务器地址</span>
          <input
            ref={addrRef}
            aria-label="服务器地址"
            className="field__input mono"
            placeholder="http://192.168.1.5:5190"
            defaultValue={initial?.baseUrl ?? DEFAULT_BASE_URL}
            autoComplete="url"
          />
        </label>
        <label className="field">
          <span className="field__label">访问令牌</span>
          <input
            ref={tokRef}
            aria-label="访问令牌"
            className="field__input mono"
            type="password"
            placeholder="server 启动时打印的 token"
            defaultValue={initial?.token ?? DEFAULT_TOKEN}
            autoComplete="current-password"
          />
        </label>
        {hint && <div className="login__hint" role="alert">{hint}</div>}
        <button type="submit" className="btn-gold btn-gold--wide">
          连接
        </button>
      </form>
    </div>
  );
}
