/**
 * 网络层统一入口（可选便捷封装）。
 *
 * UI 层可以直接用 `api()` 取 HanimeApi 单例；Application/EntryAbility 启动时调用
 * `initNetwork(ctx)` 完成 Cookie 持久化初始化（必须在第一次网络请求前）。
 *
 * 单独放一个文件是为了让 UI 只依赖 logic/net/NetFacade，而不是同时 import
 * HttpClient/CookieStore/HanimeApi 三个文件。
 */

import { common } from '@kit.AbilityKit';
import { HanimeApi } from './HanimeApi';
import { CookieStore } from './CookieStore';

/** 初始化网络层（读取持久化 cookie）。重复调用安全。 */
export async function initNetwork(ctx: common.UIAbilityContext): Promise<void> {
  await CookieStore.getInstance().init(ctx);
}

/** 全局 HanimeApi 单例快捷访问 */
export function api(): HanimeApi {
  return HanimeApi.getInstance();
}
