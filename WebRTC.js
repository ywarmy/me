// ==UserScript==
// @name         Safari WebRTC Blocker
// @namespace    http://tampermonkey.net/
// @version      3.0
// @description  Safari 专用 WebRTC 防泄露
// @match        *://*/*
// @grant        none
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    const NativeRTC =
        window.RTCPeerConnection ||
        window.webkitRTCPeerConnection;

    if (!NativeRTC) return;

    function FakeRTC(config) {

        const pc = new NativeRTC({
            iceServers: []
        });

        // 阻止 candidate 泄露
        Object.defineProperty(pc, 'onicecandidate', {
            set() {},
            get() {
                return null;
            }
        });

        // 阻止 SDP 生成
        pc.createOffer = async function () {
            throw new DOMException(
                'WebRTC disabled',
                'NotAllowedError'
            );
        };

        pc.createAnswer = async function () {
            throw new DOMException(
                'WebRTC disabled',
                'NotAllowedError'
            );
        };

        // 阻止 candidate 添加
        pc.addIceCandidate = async function () {
            return;
        };

        // 阻止本地描述
        pc.setLocalDescription = async function () {
            return;
        };

        // 清空 sender
        pc.getSenders = function () {
            return [];
        };

        // 清空 receiver
        pc.getReceivers = function () {
            return [];
        };

        // 清空 transceiver
        pc.getTransceivers = function () {
            return [];
        };

        // 直接关闭
        setTimeout(() => {
            try {
                pc.close();
            } catch (e) {}
        }, 50);

        return pc;
    }

    // 保持 prototype
    FakeRTC.prototype = NativeRTC.prototype;

    // 替换
    Object.defineProperty(window, 'RTCPeerConnection', {
        get() {
            return FakeRTC;
        },
        set() {},
        configurable: false
    });

    Object.defineProperty(window, 'webkitRTCPeerConnection', {
        get() {
            return FakeRTC;
        },
        set() {},
        configurable: false
    });

    // 阻止媒体访问
    if (navigator.mediaDevices) {

        navigator.mediaDevices.getUserMedia =
            async function () {
                throw new DOMException(
                    'Permission denied',
                    'NotAllowedError'
                );
            };

        navigator.mediaDevices.enumerateDevices =
            async function () {
                return [];
            };
    }

    // 阻止 ICE candidate
    if (window.RTCIceCandidate) {

        window.RTCIceCandidate =
            function () {
                throw new Error(
                    'ICE disabled'
                );
            };
    }

})();
