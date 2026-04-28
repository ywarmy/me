// ==UserScript==
// @name         Google 搜索极致优化 (iOS)
// @version      1.2
// @match        *://www.google.com/search*
// @match        *://www.google.com.hk/search*
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    const url = new URL(window.location.href);
    let changed = false;

    // 1. 强制语言参数 (底层逻辑锁定)
    if (url.searchParams.get('lr') !== 'lang_zh-CN') {
        url.searchParams.set('lr', 'lang_zh-CN');
        changed = true;
    }

    // 2. 界面语言同步 (hl=zh-CN 确保按钮、菜单也是中文)
    if (url.searchParams.get('hl') !== 'zh-CN') {
        url.searchParams.set('hl', 'zh-CN');
        changed = true;
    }

    // 3. 拦截跳转：使用 replace 避免产生多余的历史记录，点击“后退”不会死循环
    if (changed) {
        window.location.replace(url.toString());
    }
})();