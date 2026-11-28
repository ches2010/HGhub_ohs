import { useCallback, useEffect, useState } from "react";
import { Button, Surface, TextArea } from "../../shared/ui/ios/controls";
import { Toggle } from "../../shared/ui/ui";
import { invoke, hasHarmonyBridge } from "../../hg-bridge/core";
import { copyText, pasteText } from "../../shared/lib/clipboard";
import { useStore } from "../../shared/model/store";
import { tr } from "../../shared/i18n";
import { IBoltF, ICheck, ILink, ILockF, IRefresh } from "../../shared/ui/icons";

/* P7：对齐上游 SourceManager / SourceOnboarding 的管理体验——
   导入卡片（粘贴入口）、徽标（版本 / 示例 / 使用中 / 签名）、
   内联测试结果条、空态「试用离线示例源」；命令名与上游 v3 对齐。 */

const DEMO_OFFLINE_ID = "com.hghubx.demo-offline";

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

interface TestChip {
  ok: boolean;
  text: string;
}

function errText(e: unknown): string {
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  return String(e);
}

function sigBadge(status?: string): { text: string; cls: string } {
  if (status === "trusted") return { text: tr("受信任签名"), cls: "bg-mint/15 text-mint" };
  if (status === "unsigned") return { text: tr("未签名"), cls: "bg-danger/15 text-danger" };
  if (status === "self_signed") return { text: tr("自签名"), cls: "bg-s4 text-mut" };
  return { text: tr("签名未知"), cls: "bg-s4 text-mut" };
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
  const [tests, setTests] = useState<Record<string, TestChip>>({});

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

  // 深链等旁路导入完成后广播刷新；带 detail 时把结果回显到结果区
  useEffect(() => {
    const handler = (event: Event): void => {
      const detail = (event as CustomEvent<{ ok: boolean; message: string }>).detail;
      if (detail && detail.message.length > 0) {
        setLastResult(detail.message);
      }
      void refresh();
    };
    window.addEventListener("hg:sources-changed", handler);
    return () => window.removeEventListener("hg:sources-changed", handler);
  }, [refresh]);

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

  const doPaste = (): void => {
    if (busy.length > 0) return;
    setBusy("paste");
    void pasteText()
      .then((text) => {
        const t = text.trim();
        if (t.length > 0) setInput(t);
        else toast(tr("剪贴板为空"), "info");
      })
      .catch((e) => toast(errText(e) || tr("读取剪贴板失败，请手动粘贴"), "info"))
      .finally(() => setBusy(""));
  };

  const doImport = (): void => {
    const value = input.trim();
    if (value.length === 0) {
      toast(tr("请先粘贴分享口令、JSON 文本或 HTTPS 链接"), "info");
      return;
    }
    run("import", async () => {
      const descriptor = await invoke<{ name?: string; version?: string }>("source_import", { input: value, activate: activateOnImport });
      setInput("");
      toast(tr("已导入 {0} v{1}", String(descriptor?.name ?? ""), String(descriptor?.version ?? "")), "ok");
      return tr("{0} v{1} 导入成功", String(descriptor?.name ?? ""), String(descriptor?.version ?? ""));
    });
  };

  const doImportDemo = (): void => {
    if (busy.length > 0) return;
    setBusy("demo");
    void invoke("source_import_demo")
      .then(async () => {
        try {
          await invoke("source_activate", { id: DEMO_OFFLINE_ID });
        } catch {
          /* 已激活时忽略 */
        }
        toast(tr("已启用离线示例源"), "ok");
        await refresh();
      })
      .catch((e) => toast(errText(e), "info"))
      .finally(() => setBusy(""));
  };

  const doActivate = (id: string): void => {
    run(`activate:${id}`, async () => {
      await invoke("source_activate", { id });
      toast(tr("已启用：{0}", id), "ok");
      return tr("当前使用：{0}", id);
    });
  };

  const doTest = (id: string): void => {
    if (busy.length > 0) return;
    setBusy(`test:${id}`);
    void invoke<SourceTestReply>("source_test", { id })
      .then((reply) => {
        let chip: TestChip = { ok: true, text: tr("测试通过") };
        try {
          const parsed = JSON.parse(reply.result) as { init?: { ok?: boolean }; home?: { items?: unknown[] } };
          const ok = parsed.init?.ok === true;
          const count = Array.isArray(parsed.home?.items) ? parsed.home.items.length : null;
          chip = ok
            ? { ok: true, text: count !== null ? tr("测试通过 · {0} 条", String(count)) : tr("测试通过") }
            : { ok: false, text: tr("测试失败：init 未通过") };
        } catch {
          /* 保留默认通过态 */
        }
        setTests((prev) => ({ ...prev, [id]: chip }));
        if (chip.ok) toast(chip.text, "ok");
        else toast(chip.text, "info");
      })
      .catch((e) => {
        setTests((prev) => ({ ...prev, [id]: { ok: false, text: tr("测试失败：{0}", errText(e)) } }));
        toast(tr("测试失败：{0}", errText(e)), "info");
      })
      .finally(() => setBusy(""));
  };

  const doCheckUpdate = (id: string): void => {
    run(`update:${id}`, async () => {
      const result = await invoke<SourceUpdateResult>("source_check_update", { id });
      if (result.updated === "true") {
        toast(tr("已更新至 v{0}", result.toVersion ?? ""), "ok");
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
    <Surface className="mt-2 flex flex-col gap-3 rounded-(--r-sm) bg-s2 p-3">
      {/* 导入卡片（对齐上游 SourceManager 导入区） */}
      <Surface className="flex flex-col items-stretch gap-2 rounded-(--r-md) bg-s3/50 p-3">
        <div className="flex items-center justify-between gap-2">
          <span className="inline-flex items-center gap-1.5 text-[13px] font-semibold text-on"><ILink size={14} className="text-primary" /> {tr("导入视频源")}</span>
          <Button disabled={busy.length > 0} onClick={doPaste}
            className="h-7 rounded-(--r-sm) bg-s4 px-2.5 text-[12px] text-on pressable disabled:opacity-50">
            {busy === "paste" ? tr("读取中…") : tr("粘贴")}
          </Button>
        </div>
        <TextArea
          value={input}
          rows={3}
          aria-label={tr("视频源导入输入框")}
          placeholder={tr("粘贴 hghubx-src:// 口令、JSON 文本或 HTTPS 包地址")}
          onChange={(e) => setInput(e.target.value)}
          className="w-full font-mono text-[12px]"
        />
        <div className="ios-settings-row">
          <span className="ios-setting-icon"><ILockF size={15} /></span>
          <div className="min-w-0 flex-1">
            <div className="text-[13px] text-on">{tr("导入后直接激活")}</div>
          </div>
          <Toggle desktop on={activateOnImport} onChange={setActivateOnImport} label={tr("导入后直接激活")} />
        </div>
        <Button disabled={busy.length > 0 || input.trim().length === 0} onClick={doImport}
          className="h-9 w-full rounded-(--r-ctl) bg-primary text-[13px] font-semibold text-on-primary pressable disabled:opacity-50">
          {busy === "import" ? tr("导入中…") : tr("导入")}
        </Button>
        <div className="text-[11px] text-mut">{tr("支持分享口令、JSON 与 HTTPS 地址；在系统里打开 hghubx:// 链接会自动导入")}</div>
      </Surface>

      {/* 空态（对齐上游 SourceOnboarding / SourceManager 空态） */}
      {state !== null && installed.length === 0 && (
        <Surface className="flex flex-col items-center gap-2.5 rounded-(--r-md) bg-s3/50 p-4 text-center">
          <div className="text-[12px] text-mut">{tr("暂无视频源")}</div>
          <Button disabled={busy.length > 0} onClick={doImportDemo}
            className="h-8 rounded-(--r-sm) bg-s4 px-3 text-[12px] text-on pressable disabled:opacity-50">
            {busy === "demo" ? tr("导入中…") : tr("试用离线示例源")}
          </Button>
        </Surface>
      )}

      {installed.length > 0 && (
        <div className="px-1 text-[12px] font-semibold text-dim">{tr("已安装")}</div>
      )}

      {installed.map((entry) => {
        const active = activeId === entry.id;
        const badge = sigBadge(entry.signatureStatus);
        const chip = tests[entry.id];
        return (
          <Surface key={entry.id} className={`flex flex-col items-stretch gap-2 rounded-(--r-md) p-3 ${active ? "bg-s4/60 ring-1 ring-primary/50" : "bg-s3/50"}`}>
            <div className="flex items-center gap-1.5 flex-wrap">
              <span className="inline-flex items-center gap-1 text-[14px] font-semibold text-on"><IBoltF size={13} className="text-primary" /> {entry.name}</span>
              <span className="rounded bg-s4 px-1.5 py-0.5 font-mono text-[11px] text-mut">v{entry.version}</span>
              {entry.id === DEMO_OFFLINE_ID && (
                <span className="rounded bg-s4 px-1.5 py-0.5 text-[11px] font-medium text-mut">{tr("示例")}</span>
              )}
              {active && (
                <span className="inline-flex items-center gap-0.5 rounded bg-primary/20 px-1.5 py-0.5 text-[11px] font-medium text-primary">
                  <ICheck size={11} /> {tr("使用中")}
                </span>
              )}
              <span className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${badge.cls}`}>{badge.text}</span>
            </div>
            {entry.signatureFingerprint && entry.signatureFingerprint.length > 0 && (
              <div className="truncate font-mono text-[11px] text-mut">
                {entry.signatureFingerprint}{entry.signatureKeyId ? ` · ${entry.signatureKeyId}` : ""}
              </div>
            )}
            {chip && (
              <div className={`rounded px-2 py-1 text-[11px] ${chip.ok ? "bg-mint/15 text-mint" : "bg-danger/15 text-danger"}`}>{chip.text}</div>
            )}
            <div className="flex flex-wrap gap-1.5 pt-0.5">
              {!active && (
                <Button disabled={busy.length > 0} onClick={() => doActivate(entry.id)}
                  className="h-7 rounded-(--r-sm) bg-primary px-2.5 text-[12px] font-medium text-on-primary pressable disabled:opacity-50">
                  {busy === `activate:${entry.id}` ? tr("启用中…") : tr("启用")}
                </Button>
              )}
              <Button disabled={busy.length > 0} onClick={() => doTest(entry.id)}
                className="h-7 rounded-(--r-sm) bg-s4 px-2.5 text-[12px] text-on pressable disabled:opacity-50">
                {busy === `test:${entry.id}` ? tr("测试中…") : tr("测试")}
              </Button>
              <Button disabled={busy.length > 0} onClick={() => doCheckUpdate(entry.id)}
                className="inline-flex h-7 items-center gap-1 rounded-(--r-sm) bg-s4 px-2.5 text-[12px] text-on pressable disabled:opacity-50">
                <IRefresh size={11} /> {busy === `update:${entry.id}` ? tr("检查中…") : tr("更新")}
              </Button>
              <Button disabled={busy.length > 0} onClick={() => doExportShare(entry.id)}
                className="h-7 rounded-(--r-sm) bg-s4 px-2.5 text-[12px] text-on pressable disabled:opacity-50">
                {busy === `share:${entry.id}` ? tr("生成中…") : tr("分享口令")}
              </Button>
              <Button disabled={busy.length > 0} onClick={() => doRemove(entry.id)}
                className="ml-auto h-7 rounded-(--r-sm) bg-s4 px-2.5 text-[12px] text-danger pressable disabled:opacity-50">
                {confirmRemoveId === entry.id ? tr("再次点击确认移除") : busy === `remove:${entry.id}` ? tr("移除中…") : tr("移除")}
              </Button>
            </div>
          </Surface>
        );
      })}

      {previousId !== null && (
        <Button disabled={busy.length > 0} onClick={doRollback}
          className="ios-settings-row text-left pressable disabled:opacity-60">
          <span className="ios-setting-icon"><IRefresh size={15} /></span>
          <div className="min-w-0 flex-1">
            <div className="text-[14px] text-on">{busy === "rollback" ? tr("回滚中…") : tr("回滚到上一个激活源")}</div>
            <div className="truncate text-[12px] text-mut">{previousId}</div>
          </div>
        </Button>
      )}

      <div className="ios-settings-row">
        <span className="ios-setting-icon"><ILockF size={15} /></span>
        <div className="min-w-0 flex-1">
          <div className="text-[14px] text-on">{tr("允许导入未签名源")}</div>
          <div className="text-[12px] text-mut">{tr("关闭后只接受受信任签名；自签与未签名源将被拒绝")}</div>
        </div>
        <Toggle desktop
          on={allowUntrusted}
          disabled={busy.length > 0 || state === null}
          onChange={(on) => doSetAllowUntrusted(on)}
          label={tr("允许导入未签名源")} />
      </div>

      {loadError.length > 0 && (
        <div className="rounded-(--r-sm) bg-danger/15 p-2.5">
          <div role="alert" className="break-all text-[12px] text-danger">{loadError}</div>
        </div>
      )}

      {lastResult.length > 0 && (
        <div className="rounded-(--r-sm) bg-s3/50 p-2.5">
          <div className="select-text break-all whitespace-pre-wrap text-[12px] text-mut">{lastResult}</div>
        </div>
      )}
    </Surface>
  );
}
