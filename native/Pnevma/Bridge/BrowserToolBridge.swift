import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserToolBridge {
    private struct ToolRequestPayload {
        let callID: String
        let toolName: String
        let params: [String: Any]
    }

    private struct ToolResultParams: Encodable {
        let callID: String
        let result: JSONValue
    }

    private let bridgeEventHub: BridgeEventHub
    private let sessionProvider: @MainActor () -> BrowserWorkspaceSession?
    private let commandBusProvider: @MainActor () -> (any CommandCalling)?
    private let ensureBrowserVisible: @MainActor (URL?) -> Void
    private var observerID: UUID?

    init(
        bridgeEventHub: BridgeEventHub = .shared,
        sessionProvider: @escaping @MainActor () -> BrowserWorkspaceSession?,
        commandBusProvider: @escaping @MainActor () -> (any CommandCalling)?,
        ensureBrowserVisible: @escaping @MainActor (URL?) -> Void
    ) {
        self.bridgeEventHub = bridgeEventHub
        self.sessionProvider = sessionProvider
        self.commandBusProvider = commandBusProvider
        self.ensureBrowserVisible = ensureBrowserVisible
        startListening()
    }

    deinit {
        if let observerID {
            bridgeEventHub.removeObserver(observerID)
        }
    }

    private func startListening() {
        guard observerID == nil else { return }
        observerID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "browser_tool_request" else { return }
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: BridgeEvent) {
        guard let request = parse(event.payloadJSON) else { return }

        switch request.toolName {
        case "browser.navigate":
            handleNavigate(request)
        case "browser.get_content":
            handleGetContent(request)
        case "browser.screenshot":
            handleScreenshot(request)
        default:
            sendResult(
                callID: request.callID,
                result: [
                    "success": false,
                    "error": "unknown browser tool: \(request.toolName)",
                ]
            )
        }
    }

    private func parse(_ payloadJSON: String) -> ToolRequestPayload? {
        guard let data = payloadJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callID = json["call_id"] as? String,
              let toolName = json["tool_name"] as? String else {
            return nil
        }

        return ToolRequestPayload(
            callID: callID,
            toolName: toolName,
            params: json["params"] as? [String: Any] ?? [:]
        )
    }

    private func handleNavigate(_ request: ToolRequestPayload) {
        guard let rawURL = request.params["url"] as? String,
              let url = URL(string: rawURL) else {
            sendResult(
                callID: request.callID,
                result: ["success": false, "error": "invalid or missing url parameter"]
            )
            return
        }

        ensureBrowserVisible(url)
        guard let session = sessionProvider() else {
            sendResult(
                callID: request.callID,
                result: ["success": false, "error": "browser session unavailable"]
            )
            return
        }

        session.navigate(to: url, revealInDrawer: false)

        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let deadline = ContinuousClock.now + .seconds(25)
            try? await Task.sleep(for: .milliseconds(200))

            while session.viewModel.isLoading, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }

            self.sendResult(
                callID: request.callID,
                result: [
                    "success": true,
                    "url": session.viewModel.currentURL?.absoluteString ?? rawURL,
                    "title": session.viewModel.pageTitle,
                ]
            )
        }
    }

    private func handleGetContent(_ request: ToolRequestPayload) {
        ensureBrowserVisible(nil)
        guard let session = sessionProvider(),
              session.viewModel.shouldRenderWebView else {
            sendResult(
                callID: request.callID,
                result: ["success": false, "error": "no active browser page"]
            )
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let extracted = try await BrowserMarkdownConverter.extractMarkdown(from: session.viewModel.webView)
                self.sendResult(
                    callID: request.callID,
                    result: [
                        "success": true,
                        "title": extracted.title,
                        "url": extracted.url?.absoluteString as Any,
                        "content": extracted.markdown,
                        "excerpt": extracted.excerpt as Any,
                    ]
                )
            } catch {
                self.sendResult(
                    callID: request.callID,
                    result: [
                        "success": false,
                        "error": "content extraction failed: \(error.localizedDescription)",
                    ]
                )
            }
        }
    }

    private func handleScreenshot(_ request: ToolRequestPayload) {
        ensureBrowserVisible(nil)
        guard let session = sessionProvider(),
              session.viewModel.shouldRenderWebView else {
            sendResult(
                callID: request.callID,
                result: ["success": false, "error": "no active browser page"]
            )
            return
        }

        let config = WKSnapshotConfiguration()
        session.viewModel.webView.takeSnapshot(with: config) { [weak self] image, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.sendResult(
                        callID: request.callID,
                        result: [
                            "success": false,
                            "error": "screenshot failed: \(error.localizedDescription)",
                        ]
                    )
                    return
                }

                guard let image,
                      let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    self.sendResult(
                        callID: request.callID,
                        result: ["success": false, "error": "failed to capture screenshot"]
                    )
                    return
                }

                self.sendResult(
                    callID: request.callID,
                    result: [
                        "success": true,
                        "format": "png",
                        "encoding": "base64",
                        "data": pngData.base64EncodedString(),
                        "width": image.size.width,
                        "height": image.size.height,
                    ]
                )
            }
        }
    }

    private func sendResult(callID: String, result: [String: Any]) {
        guard let commandBus = commandBusProvider() else { return }

        Task { @MainActor in
            do {
                let _: OkResponse = try await commandBus.call(
                    method: "browser.tool_result",
                    params: ToolResultParams(
                        callID: callID,
                        result: .object(result.mapValues(JSONValue.init(any:)))
                    )
                )
            } catch {
                Log.bridge.error(
                    "browser.tool_result failed for call \(callID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
