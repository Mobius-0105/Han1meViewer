/**
 * 路由（基于 ArkUI Navigation 的 NavPathStack）。
 *
 * Index.ets 在 aboutToAppear 里调用 Router.setStack(this.pathStack)，
 * 页面内统一用 Router.openXxx() 跳转，用 Router.pop() 返回。
 */

export class RouteParam {
  videoCode: string = '';
  title: string = '';
  url: string = '';
  listCode: string = '';
  userId: string = '';
  commentId: string = '';
  query: string = '';
  genre: string = '';
}

export const ROUTE_VIDEO: string = 'video';
export const ROUTE_PLAYER: string = 'player';
export const ROUTE_SETTINGS: string = 'settings';
export const ROUTE_LOGIN: string = 'login';
export const ROUTE_WEB: string = 'web';
export const ROUTE_FAVORITES: string = 'favorites';
export const ROUTE_HISTORY: string = 'history';
export const ROUTE_ADVANCED_SEARCH: string = 'advancedSearch';
export const ROUTE_PLAYLISTS: string = 'playlists';
export const ROUTE_PLAYLIST_DETAIL: string = 'playlistDetail';
export const ROUTE_USER_ACCOUNT: string = 'userAccount';
export const ROUTE_SEARCH_RESULT: string = 'searchResult';
/** 搜索页（独立 push 页面，不再是底部 Tab） */
export const ROUTE_SEARCH: string = 'search';

/** 跨页面信号：Cloudflare 网页验证完成后自增，业务页监听到后自动重试（对齐上游 interceptor 的自动重试） */
export const CF_VERIFY_TICK_KEY: string = 'cfVerifyTick';

export class Router {
  private static stack: NavPathStack | null = null;

  static setStack(stack: NavPathStack): void {
    Router.stack = stack;
  }

  static push(name: string, param: RouteParam): void {
    if (Router.stack !== null) {
      Router.stack.pushPathByName(name, param);
    }
  }

  static pop(): void {
    if (Router.stack !== null && Router.stack.size() > 0) {
      Router.stack.pop();
    }
  }

  /**
   * 清空导航栈回到根页（首页 Tab）。
   *
   * NavPathStack.clear() 会一次性移除栈内全部二级页回到根页（Navigation 根内容即 Index），
   * 用于播放器左上角「回首页」圆钮：不逐页 pop，避免多层视频详情页一层层退。
   * 调用方通常还需要写 AppStorage['requestTab'] 把底部 Tab 切回首页。
   */
  static popToRoot(): void {
    if (Router.stack === null) {
      return;
    }
    if (Router.stack.size() <= 0) {
      return;
    }
    Router.stack.clear();
  }

  static canPop(): boolean {
    return Router.stack !== null && Router.stack.size() > 0;
  }

  static openVideo(videoCode: string): void {
    const p: RouteParam = new RouteParam();
    p.videoCode = videoCode;
    Router.push(ROUTE_VIDEO, p);
  }

  static openPlayer(videoCode: string, title: string): void {
    const p: RouteParam = new RouteParam();
    p.videoCode = videoCode;
    p.title = title;
    Router.push(ROUTE_PLAYER, p);
  }

  static openSettings(): void {
    Router.push(ROUTE_SETTINGS, new RouteParam());
  }

  static openLogin(): void {
    Router.push(ROUTE_LOGIN, new RouteParam());
  }

  static openWeb(url: string, title: string): void {
    const p: RouteParam = new RouteParam();
    p.url = url;
    p.title = title;
    Router.push(ROUTE_WEB, p);
  }

  static openFavorites(): void {
    Router.push(ROUTE_FAVORITES, new RouteParam());
  }

  static openHistory(): void {
    Router.push(ROUTE_HISTORY, new RouteParam());
  }

  static openAdvancedSearch(): void {
    Router.push(ROUTE_ADVANCED_SEARCH, new RouteParam());
  }

  static openPlaylists(userId: string): void {
    const p: RouteParam = new RouteParam();
    p.userId = userId;
    Router.push(ROUTE_PLAYLISTS, p);
  }

  static openPlaylistDetail(listCode: string, title: string): void {
    const p: RouteParam = new RouteParam();
    p.listCode = listCode;
    p.title = title;
    Router.push(ROUTE_PLAYLIST_DETAIL, p);
  }

  static openUserAccount(userId: string): void {
    const p: RouteParam = new RouteParam();
    p.userId = userId;
    Router.push(ROUTE_USER_ACCOUNT, p);
  }

  static openSearchResult(query: string): void {
    const p: RouteParam = new RouteParam();
    p.query = query;
    Router.push(ROUTE_SEARCH_RESULT, p);
  }

  /** 打开搜索页：query 为空时展示搜索历史/空态，非空时直接搜索 */
  static openSearch(query?: string): void {
    const p: RouteParam = new RouteParam();
    p.query = query !== undefined ? query : '';
    Router.push(ROUTE_SEARCH, p);
  }
}
