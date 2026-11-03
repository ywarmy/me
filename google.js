// ==UserScript==
// @name Google 搜索优化（iOS）
// @version 1.4
// @description 固定简体中文界面，搜索结果限定为中文和英文
// @match *://www.google.com/search*
// @match *://www.google.com.hk/search*
// @match *://www.google.co.jp/search*
// @run-at document-start
// ==/UserScript==
(function () {
'use strict';
const url = new URL(window.location.href);
let changed = false;
// 1. 固定 Google 界面语言为简体中文
if (url.searchParams.get('hl') !== 'zh-CN') {
url.searchParams.set('hl', 'zh-CN');
changed = true;
}
// 2. 限定搜索结果为中文和英文（多语言用 | 连接）
if (url.searchParams.get('lr') !== 'lang_zh|lang_en') {
url.searchParams.set('lr', 'lang_zh|lang_en');
changed = true;
}
// 3. 仅在参数发生变化时跳转
if (changed) {
window.location.replace(url.toString());
}
})();
