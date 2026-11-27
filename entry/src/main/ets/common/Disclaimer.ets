import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/**
 * 首次启动的年龄确认（R18 内容）。
 * 单独用一个 preferences 文件保存，避免和 AppSettings 的键冲突。
 *
 * 注意：ArkTS 禁止在普通静态方法里使用 `getContext(this)`（stand-alone this），
 * 因此 context 由 EntryAbility 启动时通过 init() 注入。
 */
const STORE_NAME: string = 'hanime_disclaimer';
const KEY_CONFIRMED: string = 'age_confirmed';

export class Disclaimer {
  private static ctx: common.UIAbilityContext | null = null;

  /** EntryAbility.onCreate 里调用一次。 */
  static init(context: common.UIAbilityContext): void {
    Disclaimer.ctx = context;
  }

  static isConfirmed(): boolean {
    const ctx: common.UIAbilityContext | null = Disclaimer.ctx;
    if (ctx === null) {
      return false;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      return store.getSync(KEY_CONFIRMED, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  static confirm(): void {
    const ctx: common.UIAbilityContext | null = Disclaimer.ctx;
    if (ctx === null) {
      return;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      store.putSync(KEY_CONFIRMED, true);
      store.flush();
    } catch (e) {
      // 忽略
    }
  }
}
