import { useMemo, useState } from 'react';
import { createDefaultStore, loadCreds, type ZStore } from './lib/store';
import { emptyChat } from './lib/chatState';
import { useStore } from 'zustand';
import { ZApi } from './lib/api';
import { LoginPage } from './pages/LoginPage';
import { SessionsPage } from './pages/SessionsPage';
import { ChatPage } from './pages/ChatPage';
import { UsagePage } from './pages/UsagePage';
import { TopBar } from './components/TopBar';
import { NewSessionDialog } from './components/NewSessionDialog';

/** 视图路由:phase(login/ready)+ main(列表/聊天)/usage 用量子页;TopBar 全局常驻。 */
export function App({ store }: { store: ZStore }) {
  const phase = useStore(store, (s) => s.phase);
  const currentSessionId = useStore(store, (s) => s.currentSessionId);
  const error = useStore(store, (s) => s.error);
  const notice = useStore(store, (s) => s.notice);
  const [sub, setSub] = useState<'none' | 'usage'>('none');
  const [showNew, setShowNew] = useState(false);
  const api = useMemo(() => {
    const c = loadCreds();
    return c ? new ZApi(c.baseUrl, c.token) : null;
  }, []);
  const view = sub === 'usage' ? 'usage' : currentSessionId ? 'chat' : 'sessions';

  const backToList = () => {
    setSub('none');
    store.setState({ currentSessionId: null, chat: emptyChat() });
  };

  if (phase === 'login') {
    const creds = loadCreds();
    return (
      <LoginPage
        initial={creds ?? undefined}
        notice={notice ?? undefined}
        onLogin={(baseUrl, token) => store.getState().login(baseUrl, token)}
      />
    );
  }
  return (
    <div className="app-shell">
      <TopBar
        store={store}
        view={view}
        onBack={backToList}
        onNewSession={() => setShowNew(true)}
        onUsage={() => { setSub('usage'); store.setState({ currentSessionId: null, chat: emptyChat() }); }}
      />
      {error && (
        <button type="button" className="strip strip--error" onClick={() => store.getState().clearError()}>
          ⚠ {error} —— 点击关闭
        </button>
      )}
      {sub === 'usage' && api ? (
        <UsagePage api={api} />
      ) : currentSessionId ? (
        <ChatPage store={store} sessionId={currentSessionId} />
      ) : (
        <SessionsPage store={store} onOpen={(id) => { store.setState({ currentSessionId: id }); }} />
      )}
      {showNew && (
        <NewSessionDialog
          store={store}
          onClose={() => setShowNew(false)}
          onOpen={(id) => { setShowNew(false); setSub('none'); store.setState({ currentSessionId: id }); }}
        />
      )}
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
    // 凭据失效(401/网络不通)时 login 会 reject:留在登录页,不能冒成未处理拒绝
    if (creds) store.getState().login(creds.baseUrl, creds.token).catch(() => {});
    // 仅装配期执行一次
  }, [store]);
  return <App store={store} />;
}

export default DefaultApp;
