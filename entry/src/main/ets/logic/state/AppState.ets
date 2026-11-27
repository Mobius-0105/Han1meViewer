/**
 * 轻量全局 UI 状态（AppStorage 镜像）。
 *
 * 职责（与根 agent 约定）：只做「设置值 → AppStorage」的灌入与登录态变更，
 * 不包含主题色（见 common/Theme.ets）与 Toast（见 common/Toast.ets）。
 *
 * 固定 AppStorage 键：baseUrl / backupCdn / themeMode / userId / username /
 * avatarUrl / loggedIn / qualityIndex / playerSpeed。
 *
 * 页面用 `@StorageLink('themeMode')` / `@StorageProp('loggedIn')` 等响应变化。
 * AppSettings.init 内部已经写过一次 AppStorage；AppState.init 可再调一次，
 * 用于「设置页改完值后刷新 UI 状态」或启动早期兜底，不会产生循环依赖。
 */

import { AppSettings } from '../settings/AppSettings';

export class AppState {
  /** 把 AppSettings 当前值全部灌入 AppStorage（同步、幂等）。 */
  static init(): void {
    const settings: AppSettings = AppSettings.getInstance();
    AppStorage.setOrCreate<string>('baseUrl', settings.getBaseUrl());
    AppStorage.setOrCreate<boolean>('backupCdn', settings.getBackupCdn());
    AppStorage.setOrCreate<string>('themeMode', settings.getThemeMode());
    AppStorage.setOrCreate<string>('userId', settings.getUserId());
    AppStorage.setOrCreate<string>('username', settings.getUsername());
    AppStorage.setOrCreate<string>('avatarUrl', settings.getAvatarUrl());
    AppStorage.setOrCreate<boolean>('loggedIn', settings.isLoggedIn());
    AppStorage.setOrCreate<number>('qualityIndex', settings.getPlayerQualityIndex());
    AppStorage.setOrCreate<number>('playerSpeed', settings.getPlayerSpeed());
  }

  /** 登录态变更（同时持久化并刷新 AppStorage 'loggedIn'）。 */
  static setLoggedIn(value: boolean): void {
    AppSettings.getInstance().setLoggedIn(value);
  }

  /** 登录成功后写入用户信息（AppStorage 的 userId/username/avatarUrl 同步刷新）。 */
  static setUser(userId: string, username: string, avatarUrl: string): void {
    const settings: AppSettings = AppSettings.getInstance();
    settings.setUserId(userId);
    settings.setUsername(username);
    settings.setAvatarUrl(avatarUrl);
  }

  /** 退出登录：清 cookie 与用户信息，保留站点/播放器等其他设置。 */
  static logout(): void {
    const settings: AppSettings = AppSettings.getInstance();
    settings.setLoggedIn(false);
    settings.setUserId('');
    settings.setUsername('');
    settings.setAvatarUrl('');
    settings.setCookieString('');
  }
}
