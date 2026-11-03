// ==UserScript==
// @name Google 搜索优化（iOS）
// @version 1.3
// @description 固定简体中文界面，不限制搜索结果语言
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
// 2. 删除语言限制，允许中文、英文、日文等搜索结果
if (url.searchParams.has('lr')) {
url.searchParams.delete('lr');
changed = true;
}
// 3. 仅在参数发生变化时跳转
if (changed) {
window.location.replace(url.toString());
}
})();
