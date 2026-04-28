// ==UserScript==
// @name        禁止自动跳转App
// @description 拦截常见网页唤起App的行为
// @author      Gemini
// @match       *://*/*
// @grant       none
// @run-at      document-start
// ==/UserScript==

(function() {
    'use strict';

    // 1. 静态拦截：移除苹果专用的智能横幅
    const removeBanners = () => {
        const meta = document.querySelector('meta[name="apple-itunes-app"]');
        if (meta) meta.remove();
    };

    // 2. 动态拦截：通过 A 标签触发的 URL Schemes
    window.addEventListener('click', (e) => {
        const a = e.target.closest('a');
        if (a && a.href) {
            // 如果协议不是 http 或 https，则判定为尝试唤起 App
            if (!a.href.startsWith('http') && !a.href.startsWith('/') && !a.href.startsWith('#')) {
                console.log('已拦截跳转请求:', a.href);
                e.preventDefault();
                e.stopImmediatePropagation();
                alert('已成功阻止此网页尝试打开 App');
            }
        }
    }, true);

    // 3. 针对部分强制跳转逻辑的定时清理
    const observer = new MutationObserver(removeBanners);
    observer.observe(document.documentElement, { childList: true, subtree: true });
})();
// 尝试通过拦截 window.location 的原型链来阻止跳转
const originalAssign = window.location.assign;
window.location.assign = function(url) {
    if (url.startsWith('http')) {
        originalAssign.call(window.location, url);
    } else {
        console.log('拦截到非 http 跳转:', url);
    }
};

// 阻止动态创建 iframe（很多广告和跳转的常用手段）
const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
        mutation.addedNodes.forEach((node) => {
            if (node.tagName === 'IFRAME' && node.src && !node.src.startsWith('http')) {
                node.remove();
                console.log('已拦截非法跳转 iframe');
            }
        });
    });
});
observer.observe(document.documentElement, { childList: true, subtree: true });
