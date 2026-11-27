/**
 * 站点加载失败自动切换备用站点（failover）。
 *
 * 背景：Cloudflare 对不同站点的风控程度不同，某个域名被拦 / 解析失败时，换一个备用域名
 * 常常直接可用（对应上游 Android README 的 `website_blocked_msg_2`）。此前只有
 * common/SiteSwitcher.ets 的手动切换；本文件把「失败 → 换站 → 重试」自动化。
 *
 * 职责划分：
 * - 触发判定 / 候选顺序 / URL 改写 / 冷却规则是纯函数，放在 core/util/SiteFailoverPolicy.ts
 *   （Node 单测直接覆盖，见 tests/logic/site_failover.test.ts）；
 * - HttpClient 在 GET 失败时通过 HttpFailoverHook 询问本类，并负责真正发重试请求；
 * - 本类负责「是否值得换站 / 候选 origin / 切换成功后落盘 + 提示」，不直接发网络请求，
 *   因此不会被 HttpClient import（避免循环依赖），由 EntryAbility 在 configure 后 install()。
 *
 * 状态约定：
 * - **不缓存当前站点**：每次从 AppSettings.getBaseUrl() 读，手动切换（SiteSwitcher）/
 *   设置页改域名后自动生效，不需要同步；
 * - 只维护时间戳：上次切换时间（切换冷却）、上次候选全部失败时间（失败冷却）、上次 Toast 时间。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BASE_URL_OPTIONS } from '../../core/util/Constants';
import {
  FAILOVER_RETRY_COOLDOWN_MS,
  FAILOVER_SWITCH_COOLDOWN_MS,
  baseUrlForOrigin,
  buildSiteSwitchToast,
  candidateOriginOf as policyCandidateOriginOf,
  cooldownActive,
  hostOfOrigin,
  normalizeOrigin,
  resolveFailoverCandidates,
  rewriteOrigin as policyRewriteOrigin,
  shouldFailoverResponse
} from '../../core/util/SiteFailoverPolicy';
import { AppSettings } from '../settings/AppSettings';
import { HanimeApi } from './HanimeApi';
import { HttpFailoverHook, HttpClient, HttpResult } from './HttpClient';
import { Toast } from '../../common/Toast';

const LOG_DOMAIN: number = 0x0001;
const TAG: string = 'SiteFailover';

/** 同一条 Toast 60s 内只弹一次（切换冷却内正常只会切一次，这里防并发/连续切换重复提示） */
const TOAST_COOLDOWN_MS: number = 60000;

/** AppStorage 键：UI 可用于显示「已自动切换站点」提示（本任务不改页面 UI） */
const STORAGE_AUTO_SWITCH_HOST: string = 'autoSwitchSiteHost';
const STORAGE_AUTO_SWITCH_AT: string = 'autoSwitchSiteAt';
const STORAGE_AUTO_SWITCH_MESSAGE: string = 'autoSwitchSiteMessage';

export class SiteFailover implements HttpFailoverHook {
  private static instance: SiteFailover | null = null;

  /** 是否已注册到 HttpClient（未注册时不参与任何请求） */
  private installed: boolean = false;

  /** 上次切换成功（自动）或手动切换的时间戳；0 = 从未，用于切换冷却 */
  private lastSwitchAt: number = 0;

  /** 上次一轮候选全部失败的时间戳；0 = 未失败，用于失败冷却（并发请求快速失败） */
  private lastFailureAt: number = 0;

  /** 上次 Toast 时间戳，避免重复提示 */
  private lastToastAt: number = 0;

  /** 最近一次切换到的 origin（仅用于日志 / 状态查询，不作为当前站点缓存） */
  private lastSwitchOrigin: string = '';

  private constructor() {
  }

  static getInstance(): SiteFailover {
    if (SiteFailover.instance === null) {
      SiteFailover.instance = new SiteFailover();
    }
    return SiteFailover.instance;
  }

  /**
   * 注册到 HttpClient。由 EntryAbility 在 `HanimeApi.configure(...)` 之后调用一次；
   * 重复调用安全（已安装则直接返回）。
   */
  static install(): void {
    const instance: SiteFailover = SiteFailover.getInstance();
    if (instance.installed) {
      return;
    }
    instance.installed = true;
    HttpClient.getInstance().setFailoverHook(instance);
    hilog.info(LOG_DOMAIN, TAG, 'site failover installed, options=%{public}d', BASE_URL_OPTIONS.length);
  }

  /**
   * 手动切换站点后同步状态（SiteSwitcher.apply 调用）：
   * 把切换冷却从现在开始算，避免用户刚手动切完、下一个失败请求又自动切走。
   * 注意：不缓存站点，当前站点始终以 AppSettings.getBaseUrl() 为准。
   */
  static noteManualSwitch(url: string): void {
    const instance: SiteFailover = SiteFailover.getInstance();
    const now: number = Date.now();
    instance.lastSwitchAt = now;
    instance.lastFailureAt = 0;
    instance.lastSwitchOrigin = normalizeOrigin(url);
    // 手动切换后清掉「自动切换」提示状态，避免 UI 显示过期的自动切换提示
    AppStorage.setOrCreate<string>(STORAGE_AUTO_SWITCH_HOST, '');
    AppStorage.setOrCreate<number>(STORAGE_AUTO_SWITCH_AT, 0);
    AppStorage.setOrCreate<string>(STORAGE_AUTO_SWITCH_MESSAGE, '');
    hilog.info(LOG_DOMAIN, TAG, 'manual switch noted: %{public}s', instance.lastSwitchOrigin);
  }

  // ---------------------------------------------------------------------------
  // 对外查询 / 纯逻辑包装（供 HttpClient 钩子与单测语义对齐）
  // ---------------------------------------------------------------------------

  /** 请求 URL 的 origin（`https://host[:port]`，无尾斜杠）；相对 URL 返回 '' */
  candidateOriginOf(url: string): string {
    return policyCandidateOriginOf(url);
  }

  /** 把 URL 的 scheme+host 替换成候选 origin，保留 path/query/hash */
  rewriteOrigin(url: string, origin: string): string {
    return policyRewriteOrigin(url, origin);
  }

  /**
   * 该次失败是否值得换站重试（对应任务要求的触发条件）：
   * - 只对 GET；POST/PUT/DELETE 等写操作永不触发，避免重复提交；
   * - result === null：底层网络异常 / 超时 / DNS → 触发；
   * - 非 2xx：403/429/500/502/503/504 或带 Cloudflare 特征 → 触发；
   * - 401/404/419/3xx 登录跳转 → 不触发；
   * - 一轮候选刚全部失败后的失败冷却内 → 不触发（并发请求快速失败）。
   */
  shouldFailover(method: http.RequestMethod, result: HttpResult | null): boolean {
    if (!this.installed) {
      return false;
    }
    if (method !== http.RequestMethod.GET) {
      return false;
    }
    if (cooldownActive(Date.now(), this.lastFailureAt, FAILOVER_RETRY_COOLDOWN_MS)) {
      return false;
    }
    if (result === null) {
      // 只有 GET 会走到这里；NetworkError/超时/DNS 换站往往有效
      return true;
    }
    return shouldFailoverResponse(result.code, result.body, result.headers);
  }

  /** HttpFailoverHook 实现（方法名对齐钩子接口） */
  shouldRetry(method: http.RequestMethod, result: HttpResult | null): boolean {
    return this.shouldFailover(method, result);
  }

  /**
   * 候选 origin 列表（HttpClient 依次重试）：
   * - 失败冷却中 / 刚切换成功的冷却中 → []（本轮放弃，保留原错误）；
   * - 当前 baseUrl 已被并发请求或用户切到别的站点 → 只返回当前站点，复用这次切换；
   * - 否则按 BASE_URL_OPTIONS 从失败站点之后环形轮询（不含失败站点）。
   */
  candidatesFor(url: string): string[] {
    if (!this.installed) {
      return [];
    }
    const now: number = Date.now();
    return resolveFailoverCandidates(
      BASE_URL_OPTIONS,
      url,
      AppSettings.getInstance().getBaseUrl(),
      now,
      this.lastSwitchAt,
      this.lastFailureAt,
      FAILOVER_SWITCH_COOLDOWN_MS,
      FAILOVER_RETRY_COOLDOWN_MS
    );
  }

  /**
   * 候选决策的便捷入口（对应任务要求的 tryNext 语义）：
   * 返回下一个可尝试的 origin；没有候选（冷却中 / 列表为空）返回 null。
   * 真正的重试请求由 HttpClient.pollCandidates 发起，本方法不发网络请求。
   */
  async tryNext(failedUrl: string): Promise<string | null> {
    const candidates: string[] = this.candidatesFor(failedUrl);
    if (candidates.length === 0) {
      return null;
    }
    return candidates[0];
  }

  /**
   * 某个候选 origin 重试成功：持久化新站点 + 让 HanimeApi 立即生效 + Toast/AppStorage 通知。
   * 若当前 baseUrl 已经是该 origin（并发请求已被别人切过去），只记录不改写、不重复提示。
   */
  onSuccess(origin: string): void {
    const normalized: string = normalizeOrigin(origin);
    if (normalized.length === 0) {
      return;
    }
    const settings: AppSettings = AppSettings.getInstance();
    const currentOrigin: string = policyCandidateOriginOf(settings.getBaseUrl());
    if (currentOrigin === normalized) {
      this.lastSwitchOrigin = normalized;
      return;
    }

    const baseUrl: string = baseUrlForOrigin(BASE_URL_OPTIONS, normalized);
    if (baseUrl.length === 0) {
      return;
    }
    try {
      // 网络层先切：保证后续（含并发的）HanimeApi 请求都用新站点
      settings.setBaseUrl(baseUrl);
      HanimeApi.getInstance().configure(baseUrl, settings.getUserAgent(), settings.getBackupCdn());
    } catch (rawError) {
      const error: Error = rawError as Error;
      hilog.error(LOG_DOMAIN, TAG, 'apply failover origin failed: %{public}s', this.messageOf(error));
      return;
    }

    const now: number = Date.now();
    this.lastSwitchAt = now;
    this.lastFailureAt = 0;
    this.lastSwitchOrigin = normalized;
    const host: string = hostOfOrigin(normalized);
    const message: string = buildSiteSwitchToast(host, settings.isLoggedIn());
    AppStorage.setOrCreate<string>(STORAGE_AUTO_SWITCH_HOST, host);
    AppStorage.setOrCreate<number>(STORAGE_AUTO_SWITCH_AT, now);
    AppStorage.setOrCreate<string>(STORAGE_AUTO_SWITCH_MESSAGE, message);
    if (!cooldownActive(now, this.lastToastAt, TOAST_COOLDOWN_MS)) {
      this.lastToastAt = now;
      Toast.show(message);
    }
    hilog.info(LOG_DOMAIN, TAG, 'auto switched site: %{public}s', baseUrl);
  }

  /** 一轮候选全部失败：设置失败冷却，不再修改 baseUrl（保留原站点给现有错误 UI） */
  onExhausted(url: string): void {
    this.lastFailureAt = Date.now();
    hilog.warn(LOG_DOMAIN, TAG, 'all failover candidates failed for: %{public}s', url);
  }

  private messageOf(error: Error): string {
    return error.message.length > 0 ? error.message : 'unknown error';
  }
}
