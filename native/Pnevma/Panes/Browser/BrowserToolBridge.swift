import Foundation
import WebKit
import AppKit

/// Bridges agent browser tool calls (from Rust via events) to the WKWebView
/// running in the Swift UI layer.
///
/// Flow:
/// 1. Rust emits `browser_tool_request` event via EventEmitter
/// 2. BrowserToolBridge observes via BridgeEventHub
/// 3. Dispatches to the active BrowserViewModel on the main thread
/// 4. Sends the result back via CommandBus ("browser.tool_result")
@MainActor
final class BrowserToolBridge {
    static let shared = BrowserToolBridge()

    private weak var activeBrowser: BrowserViewModel?
    private var observerID: UUID?

    func register(_ vm: BrowserViewModel) {
        activeBrowser = vm
    }

    func unregister(_ vm: BrowserViewModel) {
        if activeBrowser === vm {
            activeBrowser = nil
        }
    }

    func startListening() {
        guard observerID == nil else { return }
        observerID = BridgeEventHub.shared.addObserver { [weak self] event in
            guard event.name == "browser_tool_request" else { return }
            Task { @MainActor [weak self] in
                self?.handleToolRequest(event)
            }
        }
    }

    func stopListening() {
        if let id = observerID {
            BridgeEventHub.shared.removeObserver(id)
            observerID = nil
        }
    }

    // MARK: - Request Handling

    private func handleToolRequest(_ event: BridgeEvent) {
        // payloadJSON is a String — parse it
        guard let data = event.payloadJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callId = json["call_id"] as? String,
              let toolName = json["tool_name"] as? String else {
            return
        }

        let params = json["params"] as? [String: Any] ?? [:]

        guard let browser = activeBrowser else {
            sendResult(callId: callId, result: [
                "error": "no active browser pane",
                "success": false
            ])
            return
        }

        switch toolName {
        case "browser.navigate":
            handleNavigate(callId: callId, params: params, browser: browser)
        case "browser.get_content":
            handleGetContent(callId: callId, browser: browser)
        case "browser.screenshot":
            handleScreenshot(callId: callId, browser: browser)
        default:
            sendResult(callId: callId, result: [
                "error": "unknown browser tool: \(toolName)",
                "success": false
            ])
        }
    }

    // MARK: - Tool Implementations

    private func handleNavigate(callId: String, params: [String: Any], browser: BrowserViewModel) {
        guard let urlString = params["url"] as? String,
              let url = URL(string: urlString) else {
            sendResult(callId: callId, result: [
                "error": "invalid or missing url parameter",
                "success": false
            ])
            return
        }

        browser.navigate(to: url)

        // Wait for navigation to complete by observing isLoading
        Task {
            let deadline = ContinuousClock.now + .seconds(25)
            try? await Task.sleep(for: .milliseconds(200))

            while browser.isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }

            sendResult(callId: callId, result: [
                "success": true,
                "url": browser.currentURL?.absoluteString ?? urlString,
                "title": browser.pageTitle
            ])
        }
    }

    private func handleGetContent(callId: String, browser: BrowserViewModel) {
        let webView = browser.webView

        let js = """
        (function() {
            var article = document.querySelector('article') ||
                          document.querySelector('[role="main"]') ||
                          document.querySelector('main') ||
                          document.body;

            if (!article) return JSON.stringify({error: 'no content found'});

            function nodeToMarkdown(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    return node.textContent.trim();
                }
                if (node.nodeType !== Node.ELEMENT_NODE) return '';

                var tag = node.tagName.toLowerCase();
                var children = Array.from(node.childNodes).map(nodeToMarkdown).filter(Boolean).join('');

                switch(tag) {
                    case 'h1': return '\\n# ' + children + '\\n';
                    case 'h2': return '\\n## ' + children + '\\n';
                    case 'h3': return '\\n### ' + children + '\\n';
                    case 'h4': return '\\n#### ' + children + '\\n';
                    case 'p': return '\\n' + children + '\\n';
                    case 'br': return '\\n';
                    case 'a': return '[' + children + '](' + (node.href || '') + ')';
                    case 'strong': case 'b': return '**' + children + '**';
                    case 'em': case 'i': return '*' + children + '*';
                    case 'code': return '`' + children + '`';
                    case 'pre': return '\\n```\\n' + node.textContent + '\\n```\\n';
                    case 'li': return '- ' + children + '\\n';
                    case 'ul': case 'ol': return '\\n' + children;
                    case 'img': return '![' + (node.alt || '') + '](' + (node.src || '') + ')';
                    case 'script': case 'style': case 'nav': case 'footer': case 'header': return '';
                    default: return children;
                }
            }

            var md = nodeToMarkdown(article);
            md = md.replace(/\\n{3,}/g, '\\n\\n').trim();

            return JSON.stringify({
                success: true,
                title: document.title,
                url: window.location.href,
                content: md
            });
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] (result: Any?, error: (any Error)?) in
            Task { @MainActor [weak self] in
                if let error {
                    self?.sendResult(callId: callId, result: [
                        "error": "JS evaluation failed: \(error.localizedDescription)",
                        "success": false
                    ])
                    return
                }

                guard let jsonString = result as? String,
                      let jsonData = jsonString.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    self?.sendResult(callId: callId, result: [
                        "error": "failed to parse content extraction result",
                        "success": false
                    ])
                    return
                }

                self?.sendResult(callId: callId, result: parsed)
            }
        }
    }

    private func handleScreenshot(callId: String, browser: BrowserViewModel) {
        let webView = browser.webView
        let config = WKSnapshotConfiguration()

        webView.takeSnapshot(with: config) { [weak self] image, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.sendResult(callId: callId, result: [
                        "error": "screenshot failed: \(error.localizedDescription)",
                        "success": false
                    ])
                    return
                }

                guard let image,
                      let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    self?.sendResult(callId: callId, result: [
                        "error": "failed to capture screenshot",
                        "success": false
                    ])
                    return
                }

                let base64 = pngData.base64EncodedString()
                self?.sendResult(callId: callId, result: [
                    "success": true,
                    "format": "png",
                    "encoding": "base64",
                    "data": base64,
                    "width": image.size.width,
                    "height": image.size.height
                ])
            }
        }
    }

    // MARK: - Result Delivery

    private func sendResult(callId: String, result: [String: Any]) {
        // Build the full params dict with call_id and result as nested JSON
        let params: [String: Any] = [
            "call_id": callId,
            "result": result
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsJSON = String(data: data, encoding: .utf8) else {
            return
        }

        guard let bus = CommandBus.shared else { return }
        // Use the bridge directly to send the raw JSON — CommandBus.call encodes
        // params through JSONEncoder which doesn't handle [String: Any].
        // Instead, access the bridge's callAsync with the pre-serialized JSON.
        Task {
            do {
                let _: OkResponse = try await bus.callRaw(
                    method: "browser.tool_result",
                    paramsJSON: paramsJSON
                )
            } catch {
                // Best-effort — the Rust side will time out if this fails
            }
        }
    }
}
