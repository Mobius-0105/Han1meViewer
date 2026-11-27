/**
 * 常量：对应 Android 项目的 Constants.kt。
 */

export const APP_NAME: string = 'Han1meViewer';

/** 默认站点 */
export const DEFAULT_BASE_URL: string = 'https://hanime1.me/';

/** 备用域名（设置里可以切换） */
export const BASE_URL_OPTIONS: string[] = [
  'https://hanime1.me/',
  'https://hanime1.com/',
  'https://hanimeone.me/',
  'https://javchu.com/'
];

/** 默认 UA：跟着站点当前推荐的移动端 Chrome */
export const DEFAULT_USER_AGENT: string =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36';

/** 媒体 CDN 主机与备用主机 */
export const MEDIA_CDN_HOST: string = 'vdownload.hembed.com';
export const BACKUP_MEDIA_CDN_HOST: string = '1497203185.rsc.cdn77.org';

/** 评论类型 */
export const COMMENT_TYPE_VIDEO: string = 'video';
export const COMMENT_TYPE_PREVIEW: string = 'preview';

/** 站点"我的清单"类型 */
export const MYLIST_TYPE_FAV: string = 'likes';
export const MYLIST_TYPE_WATCH_LATER: string = 'saves';

/** 视频页收藏/点赞表单的 like-status 值 */
export const FAV_ADD: string = '';
export const FAV_CANCEL: string = '1';

/** 搜索页的"新番预告"类型名 */
export const NEW_ANIME_PREVIEW_GENRE: string = '新番預告';

/** 站点列表分页上限保护 */
export const MAX_PAGE_GUARD: number = 9999;

/** 首页分区标题（与解析顺序对应） */
export const HOME_SECTIONS: string[] = [
  '最新上市',
  '最新上傳',
  '裏番',
  '泡麵番',
  'Motion Anime',
  '3DCG',
  '2.5D',
  '2D',
  'AI生成',
  'MMD',
  'Cosplay',
  '他們在看',
  '新番預告'
];

export const GITHUB_REPO_URL: string = 'https://github.com/misaka10032w/Han1meViewer';
export const PROJECT_TAGLINE: string = 'Han1meViewer 的 HarmonyOS NEXT 移植版';
