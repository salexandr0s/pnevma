import XCTest
@testable import Pnevma

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct MockTreeResponse {
    let json: String
    let error: Error?
    let delayNanos: UInt64

    init(json: String, error: Error? = nil, delayNanos: UInt64 = 0) {
        self.json = json
        self.error = error
        self.delayNanos = delayNanos
    }
}

private actor MockFileBrowserCommandBus: CommandCalling {
    private var treeResponsesByPath: [String: [MockTreeResponse]]
    private let previewJSONByPath: [String: String]
    private var methodHistory: [String] = []
    private var treeRequestPaths: [String?] = []

    init(treeResponsesByPath: [String: [MockTreeResponse]], previewJSONByPath: [String: String]) {
        self.treeResponsesByPath = treeResponsesByPath
        self.previewJSONByPath = previewJSONByPath
    }

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        methodHistory.append(method)

        switch method {
        case "workspace.files.tree":
            let json = try encodeParams(params)
            let path = json["path"] as? String
            treeRequestPaths.append(path)

            let responseKey = path ?? ""
            guard var responses = treeResponsesByPath[responseKey], !responses.isEmpty else {
                throw NSError(domain: "MockFileBrowserCommandBus", code: 1)
            }

            let response = responses.removeFirst()
            treeResponsesByPath[responseKey] = responses

            if response.delayNanos > 0 {
                try? await Task.sleep(nanoseconds: response.delayNanos)
            }
            if let error = response.error {
                throw error
            }
            return try decode(response.json)

        case "workspace.file.open":
            let json = try encodeParams(params)
            guard let path = json["path"] as? String,
                  let previewJSON = previewJSONByPath[path] else {
                throw NSError(domain: "MockFileBrowserCommandBus", code: 2)
            }
            return try decode(previewJSON)

        default:
            throw NSError(domain: "MockFileBrowserCommandBus", code: 3)
        }
    }

    func methods() -> [String] {
        methodHistory
    }

    func requestedTreePaths() -> [String?] {
        treeRequestPaths
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class FileBrowserPaneTests: XCTestCase {
    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for file-browser condition", file: file, line: line)
    }

    func testLoadsRootThenDirectoryChildrenAndPreviewsSelectedFile() async throws {
        let bus = MockFileBrowserCommandBus(
            treeResponsesByPath: [
                "": [
                    MockTreeResponse(
                        json: #"""
                        [
                          {
                            "id": "src",
                            "name": "src",
                            "path": "src",
                            "is_directory": true,
                            "children": null,
                            "size": null
                          }
                        ]
                        """#
                    )
                ],
                "src": [
                    MockTreeResponse(
                        json: #"""
                        [
                          {
                            "id": "src/lib.rs",
                            "name": "lib.rs",
                            "path": "src/lib.rs",
                            "is_directory": false,
                            "children": null,
                            "size": 18
                          }
                        ]
                        """#
                    )
                ],
            ],
            previewJSONByPath: [
                "src/lib.rs": #"{"path":"src/lib.rs","content":"pub fn tree() {}\n","truncated":false,"launched_editor":false}"#
            ]
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = FileBrowserViewModel(commandBus: bus, activationHub: activationHub)

        viewModel.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            viewModel.rootNodes.count == 1 && viewModel.rootNodes.first?.children == nil
        }

        let rootNode = try XCTUnwrap(viewModel.rootNodes.first)
        viewModel.toggleDirectory(rootNode)

        try await waitUntil {
            viewModel.rootNodes.first?.children?.count == 1
        }

        let fileNode = try XCTUnwrap(viewModel.rootNodes.first?.children?.first)
        viewModel.select(fileNode)

        try await waitUntil {
            viewModel.previewContent?.contains("pub fn tree()") == true
        }

        XCTAssertTrue(viewModel.isProjectOpen)
        XCTAssertNil(viewModel.actionError)
        let methods = await bus.methods()
        let requestedTreePaths = await bus.requestedTreePaths()
        XCTAssertEqual(methods, ["workspace.files.tree", "workspace.files.tree", "workspace.file.open"])
        XCTAssertEqual(requestedTreePaths, [nil, "src"])
    }

    func testProjectNotReadyErrorClearsTreeWithoutShowingBanner() async throws {
        let bus = MockFileBrowserCommandBus(
            treeResponsesByPath: [
                "": [
                    MockTreeResponse(
                        json: "[]",
                        error: PnevmaError.backendError(
                            method: "workspace.files.tree",
                            message: "no open project"
                        )
                    )
                ]
            ],
            previewJSONByPath: [:]
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = FileBrowserViewModel(commandBus: bus, activationHub: activationHub)

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            !viewModel.isProjectOpen && viewModel.rootNodes.isEmpty && viewModel.actionError == nil
        }

        XCTAssertNil(viewModel.selectedPath)
        XCTAssertNil(viewModel.selectedFilePath)
        XCTAssertNil(viewModel.previewContent)
    }

    func testStaleRootResponseDoesNotOverwriteNewWorkspaceTree() async throws {
        let bus = MockFileBrowserCommandBus(
            treeResponsesByPath: [
                "": [
                    MockTreeResponse(
                        json: #"""
                        [
                          {
                            "id": "old.rs",
                            "name": "old.rs",
                            "path": "old.rs",
                            "is_directory": false,
                            "children": null,
                            "size": 10
                          }
                        ]
                        """#,
                        delayNanos: 200_000_000
                    ),
                    MockTreeResponse(
                        json: #"""
                        [
                          {
                            "id": "fresh.rs",
                            "name": "fresh.rs",
                            "path": "fresh.rs",
                            "is_directory": false,
                            "children": null,
                            "size": 12
                          }
                        ]
                        """#
                    ),
                ]
            ],
            previewJSONByPath: [:]
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = FileBrowserViewModel(commandBus: bus, activationHub: activationHub)

        let firstWorkspaceID = UUID()
        activationHub.update(.open(workspaceID: firstWorkspaceID, projectID: "project-1"))
        try await Task.sleep(nanoseconds: 20_000_000)
        activationHub.update(.closed(workspaceID: firstWorkspaceID))
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-2"))

        try await waitUntil {
            viewModel.rootNodes.first?.path == "fresh.rs"
        }

        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(viewModel.rootNodes.map(\.path), ["fresh.rs"])
        XCTAssertTrue(viewModel.isProjectOpen)
    }
}
