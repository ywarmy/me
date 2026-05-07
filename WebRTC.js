// ==UserScript==
// @name         屏蔽 WebRTC 泄露
// @namespace    http://tampermonkey.net/
// @version      1.1
// @description  尝试通过 Hook 禁用浏览器 WebRTC 接口，防止 IP 泄露
// @author       Gemini
// @match        *://*/*
// @grant        none
// @run-at       document-start
// ==/UserScript==

(function() {
    'use strict';

    // 定义要禁用的核心 WebRTC 构造函数和 API
    const webrtcKeys = [
        'RTCPeerConnection',
        'webkitRTCPeerConnection',
        'mozRTCPeerConnection',
        'RTCDataChannel',
        'RTCIceCandidate'
    ];

    webrtcKeys.forEach(key => {
        if (window[key]) {
            // 将这些接口重定向或置空
            Object.defineProperty(window, key, {
                value: function() {
                    console.warn(`[WebRTC Blocker] 已拦截对 ${key} 的尝试访问。`);
                    throw new Error(`${key} is disabled by script.`);
                },
                enumerable: false,
                configurable: false,
                writable: false
            });
        }
    });

    // 禁用媒体设备获取（可选，增强隐私）
    if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
        const originalEnumerate = navigator.mediaDevices.enumerateDevices;
        navigator.mediaDevices.enumerateDevices = function() {
            console.warn('[WebRTC Blocker] 已拦截媒体设备枚举。');
            return Promise.reject(new Error("Permission denied"));
        };
    }

})();
