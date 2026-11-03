// ==UserScript==
// @name Google 搜索优化（iOS）
// @version 1.6
// @description 固定简体中文界面，优先简体中文和英文，排除繁体中文及日文
// @match *://www.google.com/search*
// @match *://www.google.com.hk/search*
// @match *://www.google.co.jp/search*
// @run-at document-start
// ==/UserScript==
(function () {
'use strict';
const url = new URL(window.location.href);
let changed = false;
const params = {
hl: 'zh-CN',
lr: '(lang_zh-CN|lang_en).(-lang_zh-TW).(-lang_ja)',
c2coff: '1'
};
for (const [key, value] of Object.entries(params)) {
if (url.searchParams.get(key) !== value) {
url.searchParams.set(key, value);
changed = true;
}
}
if (changed) {
window.location.replace(url.toString());
}
})();
