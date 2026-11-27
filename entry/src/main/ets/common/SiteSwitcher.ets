import { BASE_URL_OPTIONS } from '../core/util/Constants';
import { normalizeBaseUrl } from '../core/util/Urls';
import { AppSettings } from '../logic/settings/AppSettings';
import { HanimeApi } from '../logic/net/HanimeApi';
import { SiteFailover } from '../logic/net/SiteFailover';
import { Toast } from './Toast';

/**
 * 备用站点切换（对齐上游 Android 的「切换站点」能力）。
 *
 * 为什么需要：Cloudflare 对不同站点的风控程度不同，某个域名被拦时换一个域名常常直接可用；
 * 这是上游 README/提示里明确推荐的规避手段（`website_blocked_msg_2`：
 * "網站被加固，修改為另外一個域名可能有奇效！"）。
 *
 * 切换后同时把新 baseUrl 应用到网络层；CookieStore 按 host 保存，不会串站。
 */
export class SiteSwitcher {
  /** 当前站点在 BASE_URL_OPTIONS 中的下标；不在列表中返回 0。 */
  static currentIndex(): number {
    const current: string = normalizeBaseUrl(AppSettings.getInstance().getBaseUrl());
    for (let i = 0; i < BASE_URL_OPTIONS.length; i++) {
      if (normalizeBaseUrl(BASE_URL_OPTIONS[i]) === current) {
        return i;
      }
    }
    return 0;
  }

  /** 依次轮换到下一个备用站点并应用到网络层，返回新站点。 */
  static switchToNext(): string {
    const nextIndex: number = (SiteSwitcher.currentIndex() + 1) % BASE_URL_OPTIONS.length;
    const url: string = BASE_URL_OPTIONS[nextIndex];
    SiteSwitcher.apply(url);
    Toast.show('已切换站点：' + url);
    return url;
  }

  /** 切换到指定站点并让网络层立即生效。 */
  static apply(url: string): void {
    const settings: AppSettings = AppSettings.getInstance();
    settings.setBaseUrl(url);
    HanimeApi.getInstance().configure(url, settings.getUserAgent(), settings.getBackupCdn());
    // 手动切换后同步自动切换状态（重置冷却），避免用户刚切完又被自动切走。
    // SiteFailover 不 import SiteSwitcher，因此这里是单向依赖，不构成循环 import。
    SiteFailover.noteManualSwitch(url);
  }
}
