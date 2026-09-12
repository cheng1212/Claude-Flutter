import { useMemo } from 'react';
import { createDefaultStore, loadCreds } from './lib/store';
import { useStore } from 'zustand';
import type { ZStore } from './lib/store';
import { LoginPage } from './pages/LoginPage';
import { SessionsPage } from './pages/SessionsPage';
import { ChatPage } from './pages/ChatPage';

/** 视图路由:phase(login/ready)+ currentSessionId(列表/聊天)。 */
export function App({ store }: { store: ZStore }) {
  const phase = useStore(store, (s) => s.phase);
  const currentSessionId = useStore(store, (s) => s.currentSessionId);
  const error = useStore(store, (s) => s.error);

  if (phase === 'login') {
    const creds = loadCreds();
    return (
      <LoginPage
        initial={creds ?? undefined}
        onLogin={(baseUrl, token) => void store.getState().login(baseUrl, token)}
      />
    );
  }
  return (
    <div className="app-shell">
      {error && (
        <button type="button" className="strip strip--error" onClick={() => store.getState().clearError()}>
          ⚠ {error} —— 点击关闭
        </button>
      )}
      {currentSessionId
        ? <ChatPage store={store} sessionId={currentSessionId} onBack={() => {
          store.setState({ currentSessionId: null, chat: { rows: [], lastSeq: 0, running: false } });
        }} />
        : <SessionsPage store={store} onOpen={(id) => { store.setState({ currentSessionId: id }); }} />}
    </div>
  );
}

/** 生产入口:单例 store + 本地凭据自动登录。 */
export function DefaultApp() {
  const store = useMemo(() => createDefaultStore(), []);
  const phase = useStore(store, (s) => s.phase);
  void phase;
  useMemo(() => {
    const creds = loadCreds();
    if (creds) void store.getState().login(creds.baseUrl, creds.token);
    // 仅装配期执行一次
  }, [store]);
  return <App store={store} />;
}

export default DefaultApp;
