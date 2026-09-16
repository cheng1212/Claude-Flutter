import { useState } from 'react';
import type { PermissionReq } from '../lib/chatState';

/** 权限审批卡:工具 + 输入预览 + 留言 + 允许/拒绝。 */
export function PermissionCard({ req, onAnswer }: {
  req: PermissionReq;
  onAnswer: (allow: boolean, message: string) => void;
}) {
  const [message, setMessage] = useState('');
  let input = '';
  try { input = JSON.stringify(req.input, null, 2); } catch { input = String(req.input); }

  return (
    <div className="perm">
      <div className="perm__head">
        <span className="perm__badge">◆</span>
        <span className="perm__title">权限请求 · {req.toolName}</span>
      </div>
      {input.trim() && <pre className="perm__input mono">{input}</pre>}
      <input
        aria-label="留言"
        className="perm__msg"
        placeholder="给它的留言(可空)"
        value={message}
        onChange={(e) => setMessage(e.target.value)}
      />
      <div className="perm__ops">
        <button type="button" className="btn-danger" onClick={() => onAnswer(false, message.trim())}>拒绝</button>
        <button type="button" className="btn-gold" onClick={() => onAnswer(true, message.trim())}>允许</button>
      </div>
    </div>
  );
}
