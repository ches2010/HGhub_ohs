import { useCallback, useEffect, useState } from "react";
import { Button, Surface, TextArea } from "../../shared/ui/ios/controls";
import { Toggle } from "../../shared/ui/ui";
import { invoke, hasHarmonyBridge } from "../../hg-bridge/core";
import { copyText } from "../../shared/lib/clipboard";
import { useStore } from "../../shared/model/store";
import { tr } from "../../shared/i18n";
import { IBoltF, ILink, ILockF, IRefresh } from "../../shared/ui/icons";

/* QuickJS 视频源试点（P3c）：分享口令 / HTTPS 包导入、激活、回滚、
   测试、检查更新、导出分享码与签名状态展示。命令名与上游 v3 对齐。 */

interface SourceInstallEntry {
  id: string;
  name: string;
  version: string;
  trusted: boolean;
  updatedAt: number;
  signatureStatus?: string;
  signatureKeyId?: string;
  signatureFingerprint?: string;
}

interface SourcePilotState {
  runtime: string;
  pilot: boolean;
  activeId: string | null;
  previousId: string | null;
  allowUntrusted: boolean;
  installed: SourceInstallEntry[];
}

interface SourceDescriptor {
  id: string;
  name: string;
  version: string;
  trusted: boolean;
  updatedAt: number;
  signatureStatus?: string;
  signatureKeyId?: string;
  signatureFingerprint?: string;
}

interface SourceTestReply {
  id: string;
  result: string;
}

interface SourceUpdateResult {
  updated: string;
  reason: string;
  fromVersion?: string;
  toVersion?: string;
}

const SIG_LABELS: Record<string, string> = {
  trusted: "受信任签名",
  self_signed: "自签名",
  unsigned: "未签名",
};

function sigLabel(status?: string): string {
  if (status === undefined || status.length === 0) return tr("签名未知");
  return SIG_LABELS[status] ?? status;
}

function errText(e: unknown): string {
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  return String(e);
}

export default function SourceManagerSettings() {
  const { toast } = useStore();
  const [state, setState] = useState<SourcePilotState | null>(null);
  const [loadError, setLoadError] = useState("");
  const [input, setInput] = useState("");
  const [activateOnImport, setActivateOnImport] = useState(true);
  const [busy, setBusy] = useState("");
  const [confirmRemoveId, setConfirmRemoveId] = useState("");
  const [lastResult, setLastResult] = useState("");

  const installed: SourceInstallEntry[] = state?.installed ?? [];
  const activeId: string | null = state?.activeId ?? null;
  const previousId: string | null = state?.previousId ?? null;
  const allowUntrusted: boolean = state?.allowUntrusted ?? false;

  const refresh = useCallback(async (): Promise<void> => {
    try {
      const next = await invoke<SourcePilotState>("source_state");
      setState(next);
      setLoadError("");
    } catch (e) {
      setLoadError(errText(e));
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  const run = useCallback((key: string, action: () => Promise<string>): void => {
    if (busy.length > 0) return;
    setBusy(key);
    void action()
      .then(async (message) => {
        setLastResult(message);
        await refresh();
      })
      .catch((e) => toast(errText(e), "info"))
      .finally(() => setBusy(""));
  }, [busy, refresh, toast]);

  const doImport = (): void => {
    const value = input.trim();
    if (value.length === 0) {
      toast(tr("请先粘贴分享口令、JSON 文本或 HTTPS 链接"), "info");
      return;
    }
    run("import", async () => {
      const descriptor = await invoke<SourceDescriptor>("source_import", { input: value, activate: activateOnImport });
      setInput("");
      const where = activateOnImport ? tr("已激活") : tr("未激活");
      toast(tr("导入成功"), "ok");
      return tr("{0} v{1} 导入成功（{2}，{3}）", descriptor.name, descriptor.version, sigLabel(descriptor.signatureStatus), where);
    });
  };

  const doActivate = (id: string): void => {
    run(`activate:${id}`, async () => {
      await invoke("source_activate", { id });
      toast(tr("已激活"), "ok");
      return tr("当前使用：{0}", id);
    });
  };

  const doTest = (id: string): void => {
    run(`test:${id}`, async () => {
      const reply = await invoke<SourceTestReply>("source_test", { id });
      const head = reply.result.length > 240 ? `${reply.result.slice(0, 240)}…` : reply.result;
      return tr("测试结果（{0}）：{1}", id, head);
    });
  };

  const doCheckUpdate = (id: string): void => {
    run(`update:${id}`, async () => {
      const result = await invoke<SourceUpdateResult>("source_check_update", { id });
      if (result.updated === "true") {
        toast(tr("已更新到 v{0}", result.toVersion ?? ""), "ok");
        return tr("{0} 已更新：v{1} → v{2}", id, result.fromVersion ?? "", result.toVersion ?? "");
      }
      return tr("{0} 无需更新：{1}", id, result.reason);
    });
  };

  const doExportShare = (id: string): void => {
    if (busy.length > 0) return;
    setBusy(`share:${id}`);
    void invoke<string>("source_export_share_code", { id })
      .then(async (code) => {
        try {
          await copyText(code);
          setLastResult(tr("{0} 的分享口令已复制到剪贴板", id));
          toast(tr("分享口令已复制"), "ok");
        } catch {
          setLastResult(code);
          toast(tr("复制失败，口令已显示在下方，可长按选择复制"), "info");
        }
      })
      .catch((e) => toast(errText(e), "info"))
      .finally(() => setBusy(""));
  };

  const doRemove = (id: string): void => {
    if (confirmRemoveId !== id) {
      setConfirmRemoveId(id);
      return;
    }
    setConfirmRemoveId("");
    run(`remove:${id}`, async () => {
      await invoke("source_remove", { id });
      toast(tr("已移除"), "ok");
      return tr("已移除：{0}", id);
    });
  };

  const doRollback = (): void => {
    const previous = previousId;
    run("rollback", async () => {
      await invoke("source_rollback");
      toast(tr("已回滚"), "ok");
      return tr("已回滚到：{0}", previous ?? "");
    });
  };

  const doSetAllowUntrusted = (allow: boolean): void => {
    run("allow", async () => {
      await invoke("source_set_allow_untrusted", { allow });
      return allow ? tr("已允许导入未签名源") : tr("已拒绝未签名源，仅受信任签名可导入");
    });
  };

  if (!hasHarmonyBridge()) {
    return (
      <div className="ios-settings-row">
        <span className="ios-setting-icon"><IBoltF size={16} /></span>
        <div className="flex-1">
          <div className="text-[14px] text-on">{tr("QuickJS 视频源（实验）")}</div>
          <div className="text-[12px] text-mut">{tr("当前平台未启用，仅鸿蒙版可用")}</div>
        </div>
      </div>
    );
  }

  return (
    <Surface className="mt-2 flex flex-col gap-2 rounded-(--r-sm) bg-s2 p-3">
      <div className="ios-settings-row">
        <span className="ios-setting-icon"><IBoltF size={16} /></span>
        <div className="flex-1 min-w-0">
          <div className="text-[14px] text-on">{tr("QuickJS 视频源运行时（实验功能）")}</div>
          <div className="text-[12px] text-mut">
            {loadError.length > 0
              ? <span className="text-danger">{loadError}</span>
              : state === null
                ? tr("读取中…")
                : tr("{0} 个已安装 · 当前使用：{1}", String(state.installed.length), state.activeId ?? tr("无"))}
          </div>
        </div>
      </div>

      <div className="flex flex-col items-stretch gap-2">
        <TextArea
          value={input}
          rows={3}
          aria-label={tr("视频源导入输入框")}
          placeholder={tr("粘贴 hghubx-src:// 分享口令、JSON 文本或 HTTPS 包地址")}
          onChange={(e) => setInput(e.target.value)}
          className="w-full text-[13px]"
        />
        <div className="ios-settings-row">
          <span className="ios-setting-icon"><ILockF size={15} /></span>
          <div className="flex-1 min-w-0">
            <div className="text-[14px] text-on">{tr("导入后直接激活")}</div>
            <div className="text-[12px] text-mut">{tr("关闭时仅安装，不改变当前使用的源")}</div>
          </div>
          <Toggle desktop on={activateOnImport} onChange={setActivateOnImport} label={tr("导入后直接激活")} />
        </div>
        <Button disabled={busy.length > 0} onClick={doImport}
          className="h-9 rounded-(--r-ctl) bg-primary text-[14px] font-semibold text-on-primary pressable disabled:opacity-60">
          {busy === "import" ? tr("导入中…") : tr("导入视频源")}
        </Button>
      </div>

      <div className="ios-settings-row">
        <span className="ios-setting-icon"><ILockF size={15} /></span>
        <div className="flex-1 min-w-0">
          <div className="text-[14px] text-on">{tr("允许导入未签名源")}</div>
          <div className="text-[12px] text-mut">{tr("关闭后只接受受信任签名；自签与未签名源将被拒绝")}</div>
        </div>
        <Toggle desktop
          on={allowUntrusted}
          disabled={busy.length > 0 || state === null}
          onChange={(on) => doSetAllowUntrusted(on)}
          label={tr("允许导入未签名源")} />
      </div>

      {installed.map((entry) => {
        const active = activeId === entry.id;
        return (
          <div key={entry.id} className="flex flex-col items-stretch gap-2 rounded-(--r-sm) bg-s3 p-2.5">
            <div className="flex items-center gap-2">
              <span className="ios-setting-icon"><IBoltF size={15} /></span>
              <div className="min-w-0 flex-1">
                <div className="truncate text-[14px] text-on">
                  {entry.name}
                  {active ? <span className="text-primary">{" · " + tr("使用中")}</span> : null}
                </div>
                <div className="truncate text-[12px] text-mut">
                  {`v${entry.version} · ${sigLabel(entry.signatureStatus)}${entry.signatureFingerprint ? ` · ${entry.signatureFingerprint}` : ""}`}
                </div>
              </div>
            </div>
            <div className="flex flex-wrap gap-1.5">
              {!active && (
                <Button disabled={busy.length > 0} onClick={() => doActivate(entry.id)}
                  className="h-8 rounded-(--r-ctl) bg-s3 px-3 text-[12px] text-on/80 pressable disabled:opacity-60">
                  {busy === `activate:${entry.id}` ? tr("激活中…") : tr("激活")}
                </Button>
              )}
              <Button disabled={busy.length > 0} onClick={() => doTest(entry.id)}
                className="h-8 rounded-(--r-ctl) bg-s3 px-3 text-[12px] text-on/80 pressable disabled:opacity-60">
                {busy === `test:${entry.id}` ? tr("测试中…") : tr("测试")}
              </Button>
              <Button disabled={busy.length > 0} onClick={() => doCheckUpdate(entry.id)}
                className="h-8 rounded-(--r-ctl) bg-s3 px-3 text-[12px] text-on/80 pressable disabled:opacity-60">
                {busy === `update:${entry.id}` ? tr("检查中…") : tr("检查更新")}
              </Button>
              <Button disabled={busy.length > 0} onClick={() => doExportShare(entry.id)}
                className="h-8 rounded-(--r-ctl) bg-s3 px-3 text-[12px] text-on/80 pressable disabled:opacity-60">
                {busy === `share:${entry.id}` ? tr("生成中…") : tr("分享码")}
              </Button>
              <Button variant="danger" disabled={busy.length > 0} onClick={() => doRemove(entry.id)}
                className="h-8 rounded-(--r-ctl) px-3 text-[12px] pressable disabled:opacity-60">
                {confirmRemoveId === entry.id ? tr("再次点击确认移除") : busy === `remove:${entry.id}` ? tr("移除中…") : tr("移除")}
              </Button>
            </div>
          </div>
        );
      })}

      {state !== null && installed.length === 0 && (
        <div className="text-[12px] text-mut">{tr("暂无已安装视频源，可在上方导入")}</div>
      )}

      {previousId !== null && (
        <Button disabled={busy.length > 0} onClick={doRollback}
          className="ios-settings-row text-left pressable disabled:opacity-60">
          <span className="ios-setting-icon"><IRefresh size={15} /></span>
          <div className="flex-1 min-w-0">
            <div className="text-[14px] text-on">{busy === "rollback" ? tr("回滚中…") : tr("回滚到上一个激活源")}</div>
            <div className="text-[12px] text-mut truncate">{previousId}</div>
          </div>
        </Button>
      )}

      {lastResult.length > 0 && (
        <div className="rounded-(--r-sm) bg-s3 p-2.5">
          <div className="select-text break-all whitespace-pre-wrap text-[12px] text-mut">{lastResult}</div>
        </div>
      )}
    </Surface>
  );
}
