import { useState } from 'react';
import { useStore } from 'zustand';
import type { ZStore } from '../lib/store';

/** 新建会话对话框:全局导航栏与会话列表页共用。 */
export function NewSessionDialog({ store, onClose, onOpen }: {
  store: ZStore; onClose: () => void; onOpen: (id: string) => void;
}) {
  const modelGroups = useStore(store, (s) => s.modelGroups);
  const [title, setTitle] = useState('');
  const [model, setModel] = useState('default');

  const start = async () => {
    const row = await store.getState().createSession({
      title: title.trim() || undefined,
      model: model === 'default' ? undefined : model,
    });
    onClose();
    onOpen(row.id);
  };

  return (
    <div className="dialog-mask" role="presentation">
      <div className="dialog" role="dialog" aria-label="新建会话">
        <h3 className="dialog__title">新建会话</h3>
        <label className="field">
          <span className="field__label">标题</span>
          <input aria-label="标题" className="field__input" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="可空" />
        </label>
        <label className="field">
          <span className="field__label">模型</span>
          <select aria-label="模型" className="field__input mono" value={model} onChange={(e) => setModel(e.target.value)}>
            <option value="default">默认 (Claude 官方)</option>
            {modelGroups.filter((g) => g.id !== 'default').flatMap((g) =>
              g.models.map((m) => <option key={m.id} value={m.id}>{g.label} · {m.label}</option>))}
          </select>
        </label>
        <div className="dialog__ops">
          <button type="button" className="btn-ghost" onClick={onClose}>取消</button>
          <button type="button" className="btn-gold" onClick={() => void start()}>开始</button>
        </div>
      </div>
    </div>
  );
}
