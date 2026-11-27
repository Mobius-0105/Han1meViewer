/**
 * 登录态相关的“动作”（退出登录 / 登录成功后的收尾）。
 *
 * 放在 viewmodel 里是因为 LibraryPage / UserAccountPage / LoginPage 都要用同一套逻辑：
 *  - 退出登录必须同时清掉 AppSettings 里的用户信息、CookieStore 的持久化 cookie，
 *    以及 Web 组件自己的 cookie（否则下次打开登录页会带着旧会话自动登录）；
 *  - 登录成功后要刷新“我的” Tab 的计数。
 */

import { webview } from '@kit.ArkWeb';
import { AppState } from '../../logic/state/AppState';
import { CookieStore } from '../../logic/net/CookieStore';
import { AppSettings } from '../../logic/settings/AppSettings';
import { Toast } from '../../common/Toast';
import { notifyLibraryChanged } from './LibraryViewModel';

/** 登录过期 Toast 的最小间隔（多个并发请求同时 401/302 时避免刷屏） */
const EXPIRED_TOAST_INTERVAL_MS: number = 5000;

export class SessionActions {
  /** 上次「登录已过期」Toast 的时间戳（限频用） */
  private static lastExpiredToastAt: number = 0;

  /**
   * 退出登录：清账号信息 + 所有持久化 cookie + WebView cookie。
   * 破坏性操作，调用方必须先弹 AlertDialog 确认。
   */
  static logout(): void {
    AppState.logout();
    CookieStore.getInstance().clear();
    SessionActions.clearWebViewCookies();
    notifyLibraryChanged();
  }

  /**
   * 登录过期统一处理：清 cookie / 登录态 / WebView cookie，并 Toast 提示。
   *
   * **不强制跳转登录页**（避免打断用户正在看的页面）：需要登录的操作会由业务页自行提示，
   * 用户可点「我的 → 登录」重新登录。业务页 catch 到 LoginExpiredError 时调用本方法。
   * Toast 5s 内只提示一次（收藏/评论/订阅等多个请求可能同时返回登录失效）。
   */
  static onSessionExpired(): void {
    AppState.logout();
    CookieStore.getInstance().clear();
    SessionActions.clearWebViewCookies();
    notifyLibraryChanged();
    const now: number = Date.now();
    if (now - SessionActions.lastExpiredToastAt < EXPIRED_TOAST_INTERVAL_MS) {
      return;
    }
    SessionActions.lastExpiredToastAt = now;
    Toast.show('登录已过期，请重新登录');
  }

  /**
   * 登录成功后写入 cookie 与登录态。
   * @param cookieRaw WebCookieManager.fetchCookieSync 得到的整串 cookie，或用户手动粘贴的 cookie
   */
  static applyLoginCookie(cookieRaw: string): void {
    const cookie: string = cookieRaw.trim();
    CookieStore.getInstance().setCookieString(cookie);
    const settings: AppSettings = AppSettings.getInstance();
    settings.setCookieString(cookie);
    settings.setLoggedIn(true);
    notifyLibraryChanged();
  }

  /** 清空 Web 组件 cookie（ArkWeb 内核未初始化时调用会抛错，忽略即可） */
  static clearWebViewCookies(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync();
    } catch (e) {
      // 忽略：ArkWeb 尚未初始化时清理失败不影响业务
    }
  }
}
