import { promptAction } from '@kit.ArkUI';

/** 全局轻提示 */
export class Toast {
  static show(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 2000 });
    } catch (e) {
      // 忽略：Toast 失败不应影响业务
    }
  }
}
