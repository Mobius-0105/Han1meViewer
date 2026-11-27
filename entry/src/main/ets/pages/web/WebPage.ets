/**
 * 通用 Web 容器页。
 *
 * 用途：
 *  - Cloudflare 人机验证（业务页 catch 到 CloudflareChallengeError 后 Router.openWeb(站点地址, 'Cloudflare 验证')）；
 *  - 网页播放降级（原生 AVPlayer 失败时）；
 *  - 设置页 / “我的”页里的外部链接（GitHub、许可证等）。
 *
 * 设计：
 *  - 顶栏返回 = 关闭页面；工具栏提供“重新加载”和“完成”；
 *  - “完成”：用 `webview.WebCookieManager.fetchCookieSync(webUrl)` 读网页 cookie，
 *    逐条交给 `CookieStore.saveFromResponse` 按 host 持久化；cookie 含 `cf_clearance`
 *    时再整串写入 `CookieStore.setCookieString`（任务约定的 Cloudflare 同步方式）；
 *    若网页 cookie 含站点会话 cookie，则按登录成功处理（双写 + 标记登录态）；
 *  - 打开页面时把 CookieStore 里已保存的 cookie 注入 WebView，让网页播放/验证复用登录态与
 *    Cloudflare 通行证。
 *
 * 注：ArkWeb 的 cookie 注入用 `WebCookieManager.configCookieSync(url, 'k=v; Path=/')`，
 * 该接口每次只能设置一条 cookie，所以这里按 ';' 拆分逐条设置（失败条目忽略）。
 */

import { webview } from '@kit.ArkWeb';
import { CookieStore } from '../../logic/net/CookieStore';
import { AppSettings } from '../../logic/settings/AppSettings';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router, CF_VERIFY_TICK_KEY } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar } from '../../components/common/Widgets';

/** Cloudflare 通行证 cookie 名 */
const CF_CLEARANCE: string = 'cf_clearance';

@Component
export struct WebPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：内容顶部让位 = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State pageTitle: string = '网页';
  @State webUrl: string = '';
  @State progress: number = 0;
  @State tipText: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.pageTitle = this.p.title.length > 0 ? this.p.title : '网页';
    this.webUrl = this.p.url.length > 0 ? this.p.url : AppSettings.getInstance().getBaseUrl();
    this.injectStoredCookies();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /**
   * WebView 的 UA 与网络层保持一致：Cloudflare 的 cf_clearance 与 UA 绑定，
   * 否则网页验证通过后原生请求仍会被判定为 challenge。
   */
  private applyUserAgent(): void {
    const ua: string = AppSettings.getInstance().getUserAgent();
    if (ua.length === 0) {
      return;
    }
    try {
      this.controller.setCustomUserAgent(ua);
    } catch (e) {
      // 设置 UA 失败不影响网页加载
    }
  }

  // ---------------------------------------------------------------------------
  // Cookie 同步
  // ---------------------------------------------------------------------------

  /** 是否是在访问站点自身（只对站点域注入登录 cookie，避免把会话泄露给 GitHub 等第三方页面） */
  private isSiteUrl(): boolean {
    const siteHost: string = this.hostOf(AppSettings.getInstance().getBaseUrl());
    const targetHost: string = this.hostOf(this.webUrl);
    if (siteHost.length === 0 || targetHost.length === 0) {
      return false;
    }
    return targetHost === siteHost || targetHost.endsWith('.' + siteHost) || siteHost.endsWith('.' + targetHost);
  }

  private hostOf(url: string): string {
    const lower: string = url.toLowerCase();
    const withoutScheme: string = lower.replace(/^https?:\/\//, '');
    const slash: number = withoutScheme.indexOf('/');
    return slash >= 0 ? withoutScheme.substring(0, slash) : withoutScheme;
  }

  /** 把 CookieStore 中该 URL 对应的 cookie 注入 WebView（网页播放 / CF 验证复用登录态） */
  private injectStoredCookies(): void {
    if (!this.isSiteUrl()) {
      return;
    }
    let header: string = '';
    try {
      header = CookieStore.getInstance().getCookieHeader(this.webUrl);
    } catch (e) {
      return;
    }
    if (header.length === 0) {
      return;
    }
    const pairs: string[] = header.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair: string = pairs[i].trim();
      if (pair.length === 0 || pair.indexOf('=') <= 0) {
        continue;
      }
      try {
        webview.WebCookieManager.configCookieSync(this.webUrl, pair + '; Path=/');
      } catch (e) {
        // 单条注入失败忽略
      }
    }
  }

  /** 读取 WebView 中当前 url 的 cookie（失败返回 ''） */
  private readWebCookie(): string {
    try {
      return webview.WebCookieManager.fetchCookieSync(this.webUrl);
    } catch (e) {
      return '';
    }
  }

  /**
   * 把网页 cookie 持久化到网络层：
   *  - 逐条走 saveFromResponse（按 host 保存，含 Path）；
   *  - 含 cf_clearance 时整串 setCookieString（Cloudflare 同步入口）。
   *
   * 注意：**不在这里判定/持久化登录态**。站点对游客同样下发 session cookie，
   * 若在这里 applyLoginCookie 会把"仅完成 Cloudflare 验证"的用户误标为已登录；
   * 登录态统一由 LoginPage 通过 `HanimeApi.verifyLoginLoose()` 校验后写入。
   */
  private persistCookies(cookie: string): void {
    const pairs: string[] = cookie.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair: string = pairs[i].trim();
      if (pair.length === 0 || pair.indexOf('=') <= 0) {
        continue;
      }
      try {
        CookieStore.getInstance().saveFromResponse(this.webUrl, [pair + '; Path=/']);
      } catch (e) {
        // 单条保存失败忽略
      }
    }
    if (cookie.indexOf(CF_CLEARANCE) >= 0) {
      try {
        CookieStore.getInstance().setCookieString(cookie);
      } catch (e) {
        // 忽略：saveFromResponse 已按 host 保存
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 操作
  // ---------------------------------------------------------------------------

  private reload(): void {
    this.progress = 0;
    try {
      this.controller.loadUrl(this.webUrl);
    } catch (e) {
      Toast.show('重新加载失败：' + (e as Error).message);
    }
  }

  /** “完成”按钮：同步 cookie → 关闭页面（业务页回来后重试即可） */
  private finish(): void {
    const cookie: string = this.readWebCookie();
    if (cookie.length === 0) {
      Toast.show('未读取到网页 Cookie，请确认页面已加载完成');
      Router.pop();
      return;
    }
    this.persistCookies(cookie);
    if (this.isSiteUrl()) {
      // 通知业务页"验证已完成"，首页/详情页收到后会自动重试（对齐上游自动重试）
      AppStorage.setOrCreate(CF_VERIFY_TICK_KEY, Date.now());
    }
    Toast.show(cookie.indexOf(CF_CLEARANCE) >= 0 ? '已验证并同步网页 Cookie' : '已同步网页 Cookie');
    Router.pop();
  }

  private onWebPageEnd(url: string): void {
    this.progress = 100;
    if (url.length === 0) {
      return;
    }
    const lower: string = url.toLowerCase();
    if (lower.indexOf('challenge') >= 0 || lower.indexOf('cdn-cgi') >= 0) {
      this.tipText = '检测到人机验证：请在下方网页中完成验证，然后点击“完成”。';
    } else {
      this.tipText = '';
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  build() {
    // 悬浮顶栏：WebView 不能把网页内容滚动到顶栏下方（网页内滚动由 Web 组件自己管），
    // 因此工具栏 + 网页区域整体用 spacer 下移到悬浮顶栏下方；顶栏仍是 Stack 覆盖层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 顶栏让位 spacer（状态栏 + 顶栏高度）
        Row()
          .width('100%')
          .height(this.statusBarHeight + Dimens.topBarHeight);

        // 工具条：胶囊按钮（重新加载 / 完成），中间是 Cloudflare 提示
        Row() {
          Text('重新加载')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().primary)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor(Theme.colors().chipTint)
            .backgroundBlurStyle(Glass.CHIP_BLUR)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
            .onClick(() => {
              this.reload();
            });

          if (this.tipText.length > 0) {
            Text(this.tipText)
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textHint)
              .lineHeight(16)
              .maxLines(2)
              .layoutWeight(1)
              .margin({ left: 8, right: 8 });
          } else {
            Blank();
          }

          Text('完成')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().onPrimary)
            .padding({ left: 18, right: 18, top: 8, bottom: 8 })
            .borderRadius(999)
            .backgroundColor(Theme.colors().primary)
            .onClick(() => {
              this.finish();
            });
        }
        .width('100%')
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 8, bottom: 10 });

        // 网页区域：圆角 16 裁切 + 1vp 描边，顶部 primary 进度条
        Column() {
          Column() {
            Stack({ alignContent: Alignment.TopStart }) {
              Web({ src: this.webUrl, controller: this.controller })
                .domStorageAccess(true)
                .javaScriptAccess(true)
                .mixedMode(MixedMode.All)
                .width('100%')
                .height('100%')
                .onControllerAttached(() => {
                  this.applyUserAgent();
                })
                .onProgressChange((event) => {
                  if (event) {
                    this.progress = event.newProgress;
                  }
                })
                .onPageEnd((event) => {
                  if (event) {
                    this.onWebPageEnd(event.url);
                  }
                });

              Row()
                .width(this.progress + '%')
                .height(2)
                .backgroundColor(Theme.colors().primary);
            }
            .width('100%')
            .height('100%');
          }
          .width('100%')
          .layoutWeight(1)
          .borderRadius(16)
          .clip(true)
          .backgroundColor(Theme.colors().cardBg)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        }
        .width('100%')
        .layoutWeight(1)
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + Dimens.pagePadding
        });
      }
      .width('100%')
      .height('100%');

      AppTopBar({
        title: this.pageTitle,
        showBack: true,
        actionText: '关闭',
        onAction: () => {
          Router.pop();
        }
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
