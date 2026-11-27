/**
 * 检查更新（GitHub Releases）。
 *
 * 对应 Android 版的 UpdateChecker：请求仓库的 latest release，比较 tag 与当前
 * versionName，有新版本时把说明与下载直链交给 UI 弹窗。
 *
 * 设计取舍：
 *  - 不走工程内的 HttpClient：那边会带上站点 Cookie / UA / 站点自动切换逻辑，
 *    对 api.github.com 完全是噪音，还可能把 Cookie 发到第三方域名；
 *  - 不抛异常：检查更新的结果只有「新版 / 最新 / 私有仓库 / 失败」四种，
 *    用状态字段返回，调用方直接 switch，比 try/catch 分支更直观；
 *  - 当前版本从 bundleManager 读，与 app.json5 单一来源，不写死常量。
 */

import { http } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'UpdateChecker';

/** 目标仓库固定为本项目的 GitHub 仓库（公开） */
const LATEST_URL: string = 'https://api.github.com/repos/Mobius-0105/Han1meViewer/releases/latest';

/** GitHub API 强制要求 User-Agent（缺失直接 403），顺带标明客户端身份 */
const UA: string = 'Han1meViewer-HarmonyOS';

/** 网络超时：检查更新不值得让用户等太久，失败就提示稍后重试 */
const TIMEOUT_MS: number = 10000;

/**
 * 弹窗正文上限：Release 说明常是几千字 Markdown，整段塞进弹窗会把按钮顶出屏幕，
 * 800 字约一屏半，足够看清改了什么。
 */
const BODY_MAX: number = 800;

/** 有新版本 */
export const UPDATE_NEW: string = 'new';
/** 已是最新（远端版本 <= 当前版本） */
export const UPDATE_LATEST: string = 'latest';
/** 仓库不可见（404：私有或不存在） */
export const UPDATE_PRIVATE: string = 'private';
/** 网络 / 限流 / 响应不合法等其它失败 */
export const UPDATE_FAILED: string = 'failed';

/** 检查结果：status 决定 UI 分支，其余字段只在 UPDATE_NEW 时有意义 */
export class UpdateCheckResult {
  status: string = UPDATE_FAILED;
  /** 去掉 v 前缀的版本号，例如 1.29.0 */
  version: string = '';
  /** 更新说明，已按 BODY_MAX 截断 */
  body: string = '';
  /** 优先 .hap 直链，其次 Release 页面；可能为空 */
  url: string = '';
}

export class UpdateChecker {
  /** 当前安装包的 versionName（读不到时返回空串，调用方降级显示） */
  static currentVersionName(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'read bundle info failed');
      return '';
    }
  }

  /** 当前安装包的 versionCode（读不到时返回 0） */
  static currentVersionCode(): number {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionCode;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'read bundle info failed');
      return 0;
    }
  }

  /**
   * 请求 latest release 并与当前 versionName 比较。
   *
   * 返回值 status：
   *  - UPDATE_NEW     → 有新版本，version/body/url 已填好；
   *  - UPDATE_LATEST  → 已是最新；
   *  - UPDATE_PRIVATE → 404，仓库未公开；
   *  - UPDATE_FAILED  → 断网 / 超时 / 限流 / 返回体解析不出来。
   */
  static async checkLatest(): Promise<UpdateCheckResult> {
    const result: UpdateCheckResult = new UpdateCheckResult();
    const headers: Record<string, string> = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': UA,
      'X-GitHub-Api-Version': '2022-11-28'
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      // 检查更新必须拿服务端最新结果，禁用本地 HTTP 缓存
      usingCache: false
    };

    const request: http.HttpRequest = http.createHttp();
    let code: number = 0;
    let text: string = '';
    try {
      const response: http.HttpResponse = await request.request(LATEST_URL, options);
      code = response.responseCode;
      // expectDataType=STRING 时正常就是 string，这里仍做类型判定，防止网关异常返回
      if (typeof response.result === 'string') {
        text = response.result;
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0x0000, TAG, 'request failed: %{public}d', err.code);
      result.status = UPDATE_FAILED;
      return result;
    } finally {
      request.destroy();
    }

    // 404 是仓库私有 / 不存在时 GitHub 的固定表现，必须单独回，否则会被当成网络故障
    if (code === 404) {
      result.status = UPDATE_PRIVATE;
      return result;
    }
    if (code !== 200 || text.length === 0) {
      hilog.warn(0x0000, TAG, 'unexpected http %{public}d', code);
      result.status = UPDATE_FAILED;
      return result;
    }

    const info: UpdateCheckResult | null = UpdateChecker.parse(text);
    if (info === null) {
      hilog.warn(0x0000, TAG, 'bad payload');
      result.status = UPDATE_FAILED;
      return result;
    }

    const current: string = UpdateChecker.currentVersionName();
    info.status = UpdateChecker.compareVersion(info.version, current) > 0 ? UPDATE_NEW : UPDATE_LATEST;
    return info;
  }

  /**
   * 按 x.y.z 逐段比较数字：1.10.0 > 1.9.0。
   *
   * 不能用字符串比较（字典序下 '1.10.0' < '1.9.0'），否则每次小版本更新都会被判成
   * 「已是最新」。缺段按 0 补（1.2 == 1.2.0），非数字段取数字前缀（0-beta → 0）。
   * 返回 1 表示 a 更新，-1 表示 b 更新，0 表示相同。
   */
  static compareVersion(a: string, b: string): number {
    const pa: string[] = a.trim().split('.');
    const pb: string[] = b.trim().split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x: number = i < pa.length ? UpdateChecker.segment(pa[i]) : 0;
      const y: number = i < pb.length ? UpdateChecker.segment(pb[i]) : 0;
      if (x !== y) {
        return x > y ? 1 : -1;
      }
    }
    return 0;
  }

  /** 单段转数字：用 parseInt 而不是 Number，'0-beta' 才是 0 而不是 NaN */
  private static segment(s: string): number {
    const v: number = parseInt(s.trim(), 10);
    return Number.isNaN(v) ? 0 : v;
  }

  /**
   * 解析 Release JSON。
   *
   * 用 Record 逐层取值而不是定义镜像类：GitHub 字段名（tag_name / html_url）不符合
   * 工程命名习惯，且 body 允许为 null，逐层判型最省事。
   */
  private static parse(text: string): UpdateCheckResult | null {
    try {
      const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;

      const tagRaw: Object | undefined = root['tag_name'];
      if (tagRaw === undefined || typeof tagRaw !== 'string') {
        return null;
      }
      const version: string = UpdateChecker.stripV(tagRaw as string);
      if (version.length === 0) {
        return null;
      }

      const info: UpdateCheckResult = new UpdateCheckResult();
      info.version = version;

      const bodyRaw: Object | undefined = root['body'];
      if (bodyRaw !== undefined && typeof bodyRaw === 'string' && (bodyRaw as string).trim().length > 0) {
        info.body = UpdateChecker.clip(bodyRaw as string);
      } else {
        // body: null 是 Release 的合法取值（发布时没填说明）
        info.body = '该版本没有填写更新说明。';
      }
      info.url = UpdateChecker.pickUrl(root);
      return info;
    } catch (e) {
      return null;
    }
  }

  /**
   * 下载地址：优先 .hap 资源直链，其次 Release 页面。
   *
   * 只认 .hap：Release 里可能同时挂源码包和文档，随便取第一个会把用户引到装不上的文件。
   */
  private static pickUrl(root: Record<string, Object>): string {
    const assetsRaw: Object | undefined = root['assets'];
    if (assetsRaw !== undefined && assetsRaw !== null) {
      const assets: Object[] = assetsRaw as Object[];
      for (let i = 0; i < assets.length; i++) {
        const asset: Record<string, Object> = assets[i] as Record<string, Object>;
        const nameRaw: Object | undefined = asset['name'];
        if (nameRaw === undefined || typeof nameRaw !== 'string') {
          continue;
        }
        if (!(nameRaw as string).toLowerCase().endsWith('.hap')) {
          continue;
        }
        const dlRaw: Object | undefined = asset['browser_download_url'];
        if (dlRaw !== undefined && typeof dlRaw === 'string' && (dlRaw as string).length > 0) {
          return dlRaw as string;
        }
      }
    }
    const htmlRaw: Object | undefined = root['html_url'];
    return htmlRaw !== undefined && typeof htmlRaw === 'string' ? htmlRaw as string : '';
  }

  /** tag_name 形如 v1.29.0，剥掉前缀 v（大小写都认）才是能与 versionName 直接比的版本号 */
  private static stripV(tag: string): string {
    let s: string = tag.trim();
    if (s.length > 0 && (s.charAt(0) === 'v' || s.charAt(0) === 'V')) {
      s = s.substring(1);
    }
    return s.trim();
  }

  /** 截到 BODY_MAX 字，剪断处补省略号 */
  private static clip(s: string): string {
    const t: string = s.trim();
    return t.length > BODY_MAX ? t.substring(0, BODY_MAX) + '…' : t;
  }
}
