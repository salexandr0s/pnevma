import XCTest
@testable import Pnevma

private struct FavoriteRequest: Sendable, Equatable {
    let sourceKey: String
    let favorite: Bool
}

private struct WriteRequest: Sendable, Equatable {
    let sourceKey: String
    let content: String
}

private struct RenameCollectionRequest: Sendable, Equatable {
    let id: String
    let name: String
}

private struct InstallRequest: Sendable, Equatable {
    let sourceKey: String
    let replaceExisting: Bool
    let allowCopyFallback: Bool
    let targets: [HarnessTargetParams]
}

private actor HarnessCatalogCommandBusStub: CommandCalling {
    enum StubError: Error {
        case unsupportedMethod(String)
        case badParams(String)
    }

    var snapshotResponses: [HarnessCatalogSnapshot]
    var readResponses: [String: HarnessCatalogReadContent]
    var createPlanResponse: HarnessCreatePlan?
    var createResult: HarnessMutationResult?
    var installPlanResponse: HarnessInstallPlan?
    var installResult: HarnessMutationResult?
    var readDelayNanos: [String: UInt64]
    private(set) var favoriteRequests: [FavoriteRequest] = []
    private(set) var writeRequests: [WriteRequest] = []
    private(set) var renameRequests: [RenameCollectionRequest] = []
    private(set) var installRequests: [InstallRequest] = []
    private(set) var methodHistory: [String] = []

    init(
        snapshotResponses: [HarnessCatalogSnapshot],
        readResponses: [String: HarnessCatalogReadContent],
        createPlanResponse: HarnessCreatePlan? = nil,
        createResult: HarnessMutationResult? = nil,
        installPlanResponse: HarnessInstallPlan? = nil,
        installResult: HarnessMutationResult? = nil,
        readDelayNanos: [String: UInt64] = [:]
    ) {
        self.snapshotResponses = snapshotResponses
        self.readResponses = readResponses
        self.createPlanResponse = createPlanResponse
        self.createResult = createResult
        self.installPlanResponse = installPlanResponse
        self.installResult = installResult
        self.readDelayNanos = readDelayNanos
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        methodHistory.append(method)

        switch method {
        case "harness.catalog.snapshot":
            guard !snapshotResponses.isEmpty else {
                throw StubError.unsupportedMethod(method)
            }
            let response = snapshotResponses.removeFirst()
            return try decodeJSON(jsonSnapshot(response))

        case "harness.catalog.read":
            let json = try encodeParams(params)
            guard let sourceKey = json["source_key"] as? String,
                  let response = readResponses[sourceKey] else {
                throw StubError.badParams(method)
            }
            if let delay = readDelayNanos[sourceKey], delay > 0 {
                try await Task.sleep(nanoseconds: delay)
            }
            return try decodeJSON(jsonReadContent(response))

        case "harness.catalog.write":
            let json = try encodeParams(params)
            guard let sourceKey = json["source_key"] as? String,
                  let content = json["content"] as? String else {
                throw StubError.badParams(method)
            }
            writeRequests.append(WriteRequest(sourceKey: sourceKey, content: content))
            return try decodeJSON(["ok": true])

        case "harness.catalog.favorite":
            let json = try encodeParams(params)
            guard let sourceKey = json["source_key"] as? String,
                  let favorite = json["favorite"] as? Bool else {
                throw StubError.badParams(method)
            }
            favoriteRequests.append(FavoriteRequest(sourceKey: sourceKey, favorite: favorite))
            return try decodeJSON(["ok": true])

        case "harness.catalog.collections.create":
            return try decodeJSON(["id": "collection-1", "name": "New", "item_count": 0])

        case "harness.catalog.collections.rename":
            let json = try encodeParams(params)
            guard let id = json["id"] as? String,
                  let name = json["name"] as? String else {
                throw StubError.badParams(method)
            }
            renameRequests.append(RenameCollectionRequest(id: id, name: name))
            return try decodeJSON(["ok": true])

        case "harness.catalog.collections.delete",
             "harness.catalog.collections.set_membership",
             "harness.catalog.scan_roots.upsert",
             "harness.catalog.scan_roots.set_enabled",
             "harness.catalog.scan_roots.delete",
             "harness.catalog.install.remove":
            return try decodeJSON(["ok": true])

        case "harness.catalog.create.plan":
            guard let createPlanResponse else {
                throw StubError.unsupportedMethod(method)
            }
            return try decodeJSON(jsonCreatePlan(createPlanResponse))

        case "harness.catalog.create.apply":
            guard let createResult else {
                throw StubError.unsupportedMethod(method)
            }
            return try decodeJSON(jsonMutationResult(createResult))

        case "harness.catalog.install.plan":
            guard let installPlanResponse else {
                throw StubError.unsupportedMethod(method)
            }
            return try decodeJSON(jsonInstallPlan(installPlanResponse))

        case "harness.catalog.install.apply":
            let json = try encodeParams(params)
            let targets = (json["targets"] as? [[String: Any]] ?? []).compactMap { target -> HarnessTargetParams? in
                guard let tool = target["tool"] as? String,
                      let scope = target["scope"] as? String else {
                    return nil
                }
                return HarnessTargetParams(tool: tool, scope: scope)
            }
            installRequests.append(
                InstallRequest(
                    sourceKey: json["source_key"] as? String ?? "",
                    replaceExisting: json["replace_existing"] as? Bool ?? false,
                    allowCopyFallback: json["allow_copy_fallback"] as? Bool ?? false,
                    targets: targets
                )
            )
            guard let installResult else {
                throw StubError.unsupportedMethod(method)
            }
            return try decodeJSON(jsonMutationResult(installResult))

        default:
            throw StubError.unsupportedMethod(method)
        }
    }

    func writes() -> [WriteRequest] {
        writeRequests
    }

    func favorites() -> [FavoriteRequest] {
        favoriteRequests
    }

    func renameCalls() -> [RenameCollectionRequest] {
        renameRequests
    }

    func methods() -> [String] {
        methodHistory
    }

    func installs() -> [InstallRequest] {
        installRequests
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func decodeJSON<T: Decodable>(_ value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try PnevmaJSON.decoder().decode(T.self, from: data)
    }

    private func jsonSnapshot(_ snapshot: HarnessCatalogSnapshot) -> [String: Any] {
        [
            "items": snapshot.items.map(jsonItem),
            "collections": snapshot.collections.map { [
                "id": $0.id,
                "name": $0.name,
                "item_count": $0.itemCount,
            ] },
            "scan_roots": snapshot.scanRoots.map { [
                "id": $0.id,
                "path": $0.path,
                "label": $0.label as Any,
                "enabled": $0.enabled,
            ] },
            "analytics": [
                "total_items": snapshot.analytics.totalItems,
                "favorite_count": snapshot.analytics.favoriteCount,
                "collection_count": snapshot.analytics.collectionCount,
                "folder_backed_count": snapshot.analytics.folderBackedCount,
                "heavy_count": snapshot.analytics.heavyCount,
                "by_kind": snapshot.analytics.byKind.map { ["key": $0.key, "count": $0.count] },
                "by_tool": snapshot.analytics.byTool.map { ["key": $0.key, "count": $0.count] },
                "by_scope": snapshot.analytics.byScope.map { ["key": $0.key, "count": $0.count] },
            ],
            "capabilities": [
                "library_root_path": snapshot.capabilities.libraryRootPath,
                "creatable_kinds": snapshot.capabilities.creatableKinds.map { kind in
                    [
                        "kind": kind.kind,
                        "default_primary_file": kind.defaultPrimaryFile,
                        "default_format": kind.defaultFormat,
                        "allowed_targets": kind.allowedTargets.map { option in
                            [
                                "tool": option.tool,
                                "scope": option.scope,
                                "enabled": option.enabled,
                                "reason_disabled": option.reasonDisabled as Any,
                            ]
                        },
                    ]
                },
            ],
        ]
    }

    private func jsonReadContent(_ value: HarnessCatalogReadContent) -> [String: Any] {
        [
            "source_key": value.sourceKey,
            "content": value.content,
            "format": value.format,
            "path": value.path,
        ]
    }

    private func jsonMutationResult(_ value: HarnessMutationResult) -> [String: Any] {
        [
            "source_key": value.sourceKey,
            "source_path": value.sourcePath,
            "source_root_path": value.sourceRootPath,
            "warnings": value.warnings,
        ]
    }

    private func jsonCreatePlan(_ value: HarnessCreatePlan) -> [String: Any] {
        [
            "source_mode": value.sourceMode,
            "source_path": value.sourcePath,
            "source_root_path": value.sourceRootPath,
            "slug": value.slug,
            "template_content": value.templateContent,
            "operations": value.operations.map(jsonOperation),
            "warnings": value.warnings,
        ]
    }

    private func jsonInstallPlan(_ value: HarnessInstallPlan) -> [String: Any] {
        [
            "source_mode": value.sourceMode,
            "source_path": value.sourcePath,
            "source_root_path": value.sourceRootPath,
            "source_key": value.sourceKey as Any,
            "slug": value.slug,
            "requires_promotion": value.requiresPromotion,
            "operations": value.operations.map(jsonOperation),
            "warnings": value.warnings,
        ]
    }

    private func jsonOperation(_ value: HarnessPlannedOperation) -> [String: Any] {
        [
            "action": value.action,
            "path": value.path,
            "tool": value.tool,
            "scope": value.scope,
            "backing_mode": value.backingMode,
            "conflict": value.conflict as Any,
            "note": value.note as Any,
        ]
    }

    private func jsonItem(_ value: HarnessCatalogItem) -> [String: Any] {
        [
            "source_key": value.sourceKey,
            "display_name": value.displayName,
            "summary": value.summary as Any,
            "kind": value.kind,
            "source_mode": value.sourceMode,
            "primary_tool": value.primaryTool,
            "primary_scope": value.primaryScope,
            "tools": value.tools,
            "scopes": value.scopes,
            "format": value.format,
            "primary_path": value.primaryPath,
            "primary_root_path": value.primaryRootPath,
            "canonical_path": value.canonicalPath,
            "exists": value.exists,
            "folder_backed": value.folderBacked,
            "size_bytes": NSNumber(value: value.sizeBytes),
            "install_count": value.installCount,
            "support_file_count": value.supportFileCount,
            "is_favorite": value.isFavorite,
            "collections": value.collections,
            "is_heavy": value.isHeavy,
            "installs": value.installs.map { install in
                [
                    "path": install.path,
                    "root_path": install.rootPath,
                    "tool": install.tool,
                    "scope": install.scope,
                    "format": install.format,
                    "exists": install.exists,
                    "backing_mode": install.backingMode,
                    "status": install.status,
                    "removal_policy": install.removalPolicy,
                ]
            },
            "support_files": value.supportFiles.map { file in
                [
                    "rel_path": file.relPath,
                    "path": file.path,
                    "format": file.format,
                    "size_bytes": NSNumber(value: file.sizeBytes),
                ]
            },
        ]
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        self.encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

@MainActor
final class HarnessConfigPaneTests: XCTestCase {
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
        XCTFail("Timed out waiting for harness-config condition", file: file, line: line)
    }

    private func makeTarget(tool: String, scope: String, enabled: Bool = true) -> HarnessTargetOption {
        HarnessTargetOption(tool: tool, scope: scope, enabled: enabled, reasonDisabled: enabled ? nil : "disabled")
    }

    private func makeCapabilities() -> HarnessCatalogCapabilities {
        HarnessCatalogCapabilities(
            libraryRootPath: "/Users/test/.config/pnevma/harness-library",
            creatableKinds: [
                HarnessCreatableKind(
                    kind: "skill",
                    defaultPrimaryFile: "SKILL.md",
                    defaultFormat: "markdown",
                    allowedTargets: [
                        makeTarget(tool: "claude", scope: "user"),
                        makeTarget(tool: "codex", scope: "user"),
                        makeTarget(tool: "pnevma", scope: "library", enabled: false),
                    ]
                ),
            ]
        )
    }

    private func makeInstall(
        path: String,
        rootPath: String,
        tool: String,
        scope: String,
        exists: Bool = true,
        backingMode: String = "source",
        status: String = "ok",
        removalPolicy: String = "source"
    ) -> HarnessInstall {
        HarnessInstall(
            path: path,
            rootPath: rootPath,
            tool: tool,
            scope: scope,
            format: "markdown",
            exists: exists,
            backingMode: backingMode,
            status: status,
            removalPolicy: removalPolicy
        )
    }

    private func makeItem(
        sourceKey: String,
        displayName: String,
        sourceMode: String = "native",
        primaryTool: String = "codex",
        primaryScope: String = "user",
        installs: [HarnessInstall]? = nil,
        isFavorite: Bool = false
    ) -> HarnessCatalogItem {
        let installs = installs ?? [makeInstall(
            path: "/tmp/\(displayName)/SKILL.md",
            rootPath: "/tmp/\(displayName)",
            tool: primaryTool,
            scope: primaryScope
        )]
        return HarnessCatalogItem(
            sourceKey: sourceKey,
            displayName: displayName,
            summary: "Summary for \(displayName)",
            kind: "skill",
            sourceMode: sourceMode,
            primaryTool: primaryTool,
            primaryScope: primaryScope,
            tools: Array(Set(installs.map(\.tool) + [primaryTool])).sorted(),
            scopes: Array(Set(installs.map(\.scope) + [primaryScope])).sorted(),
            format: "markdown",
            primaryPath: installs.first?.path ?? "/tmp/\(displayName)/SKILL.md",
            primaryRootPath: installs.first?.rootPath ?? "/tmp/\(displayName)",
            canonicalPath: installs.first?.path ?? "/tmp/\(displayName)/SKILL.md",
            exists: true,
            folderBacked: true,
            sizeBytes: 1200,
            installCount: installs.count,
            supportFileCount: 0,
            isFavorite: isFavorite,
            collections: [],
            isHeavy: false,
            installs: installs,
            supportFiles: []
        )
    }

    private func makeSnapshot(items: [HarnessCatalogItem]) -> HarnessCatalogSnapshot {
        HarnessCatalogSnapshot(
            items: items,
            collections: [HarnessCollection(id: "col-1", name: "Favorites", itemCount: items.count)],
            scanRoots: [HarnessScanRoot(id: "root-1", path: "/tmp/skills", label: "Temp", enabled: true)],
            analytics: HarnessCatalogAnalytics(
                totalItems: items.count,
                favoriteCount: items.filter(\.isFavorite).count,
                collectionCount: 1,
                folderBackedCount: items.count,
                heavyCount: 0,
                byKind: [HarnessCount(key: "skill", count: items.count)],
                byTool: [HarnessCount(key: items.first?.primaryTool ?? "codex", count: items.count)],
                byScope: [HarnessCount(key: items.first?.primaryScope ?? "user", count: items.count)]
            ),
            capabilities: makeCapabilities()
        )
    }

    func testActivateLoadsSnapshotAndSelectsFirstItem() async throws {
        let alpha = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [alpha])],
            readResponses: [:]
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())

        await viewModel.activate()

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.selectedSourceKey, "alpha")
        XCTAssertEqual(viewModel.capabilities?.creatableKinds.first?.kind, "skill")
    }

    func testLoadSelectedItemReadsContentIntoEditor() async throws {
        let alpha = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [alpha])],
            readResponses: [
                "alpha": HarnessCatalogReadContent(
                    sourceKey: "alpha",
                    content: "# Alpha\nHello harness\n",
                    format: "markdown",
                    path: "/tmp/alpha/SKILL.md"
                )
            ]
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()

        viewModel.loadSelectedItem()

        try await waitUntil {
            viewModel.editorContent == "# Alpha\nHello harness\n"
                && viewModel.originalContent == "# Alpha\nHello harness\n"
                && !viewModel.hasUnsavedChanges
        }
    }

    func testSaveSelectedItemWritesCurrentEditorContentAndRefreshesSnapshot() async throws {
        let alpha = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let refreshedAlpha = makeItem(sourceKey: "alpha", displayName: "Alpha", isFavorite: true)
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [alpha]), makeSnapshot(items: [refreshedAlpha])],
            readResponses: [
                "alpha": HarnessCatalogReadContent(
                    sourceKey: "alpha",
                    content: "# Alpha\n",
                    format: "markdown",
                    path: "/tmp/alpha/SKILL.md"
                )
            ]
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()
        viewModel.editorContent = "# Alpha\nUpdated\n"
        viewModel.originalContent = "# Alpha\n"
        viewModel.hasUnsavedChanges = true

        viewModel.saveSelectedItem()

        try await waitUntil {
            !viewModel.isSaving && !viewModel.hasUnsavedChanges && viewModel.originalContent == "# Alpha\nUpdated\n"
        }

        let writes = await bus.writes()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.sourceKey, "alpha")
        XCTAssertEqual(writes.first?.content, "# Alpha\nUpdated\n")

        let methods = await bus.methods()
        XCTAssertEqual(
            methods,
            [
                "harness.catalog.snapshot",
                "harness.catalog.write",
                "harness.catalog.snapshot",
            ]
        )
        XCTAssertEqual(viewModel.selectedSourceKey, "alpha")
        XCTAssertEqual(viewModel.items.first?.isFavorite, true)
    }

    func testStaleReadDoesNotOverwriteNewerSelection() async throws {
        let alpha = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let beta = makeItem(sourceKey: "beta", displayName: "Beta")
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [alpha, beta])],
            readResponses: [
                "alpha": HarnessCatalogReadContent(
                    sourceKey: "alpha",
                    content: "# Alpha\nLate\n",
                    format: "markdown",
                    path: "/tmp/alpha/SKILL.md"
                ),
                "beta": HarnessCatalogReadContent(
                    sourceKey: "beta",
                    content: "# Beta\nFresh\n",
                    format: "markdown",
                    path: "/tmp/beta/SKILL.md"
                ),
            ],
            readDelayNanos: ["alpha": 250_000_000]
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()

        viewModel.selectedSourceKey = "alpha"
        viewModel.loadSelectedItem()
        viewModel.selectedSourceKey = "beta"
        viewModel.loadSelectedItem()

        try await waitUntil(timeoutNanos: 2_000_000_000) {
            viewModel.editorContent == "# Beta\nFresh\n"
        }

        XCTAssertEqual(viewModel.originalContent, "# Beta\nFresh\n")
    }

    func testCreateItemAppliesAndSelectsReturnedSourceKey() async throws {
        let existing = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let created = makeItem(
            sourceKey: "library-skill",
            displayName: "Generated Skill",
            sourceMode: "library",
            primaryTool: "pnevma",
            primaryScope: "library",
            installs: [
                makeInstall(
                    path: "/Users/test/.config/pnevma/harness-library/skill/generated-skill/SKILL.md",
                    rootPath: "/Users/test/.config/pnevma/harness-library/skill/generated-skill",
                    tool: "pnevma",
                    scope: "library"
                )
            ]
        )
        let createPlan = HarnessCreatePlan(
            sourceMode: "library",
            sourcePath: created.primaryPath,
            sourceRootPath: created.primaryRootPath,
            slug: "generated-skill",
            templateContent: "# Generated Skill\n",
            operations: [
                HarnessPlannedOperation(
                    action: "write_source",
                    path: created.primaryPath,
                    tool: "pnevma",
                    scope: "library",
                    backingMode: "source",
                    conflict: nil,
                    note: nil
                )
            ],
            warnings: []
        )
        let createResult = HarnessMutationResult(
            sourceKey: created.sourceKey,
            sourcePath: created.primaryPath,
            sourceRootPath: created.primaryRootPath,
            warnings: []
        )
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [existing]), makeSnapshot(items: [existing, created])],
            readResponses: [
                created.sourceKey: HarnessCatalogReadContent(
                    sourceKey: created.sourceKey,
                    content: "# Generated Skill\n",
                    format: "markdown",
                    path: created.primaryPath
                )
            ],
            createPlanResponse: createPlan,
            createResult: createResult
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()

        let plan = await viewModel.planCreateItem(
            kind: "skill",
            name: "Generated Skill",
            targets: [HarnessTargetParams(tool: "claude", scope: "user")],
            replaceExisting: false
        )
        XCTAssertEqual(plan?.slug, "generated-skill")

        let result = await viewModel.createItem(
            kind: "skill",
            name: "Generated Skill",
            slug: plan?.slug,
            content: "# Generated Skill\n",
            targets: [HarnessTargetParams(tool: "claude", scope: "user")],
            replaceExisting: false,
            allowCopyFallback: true
        )
        XCTAssertEqual(result?.sourceKey, created.sourceKey)

        try await waitUntil {
            viewModel.selectedSourceKey == created.sourceKey
        }
    }

    func testInstallItemPromotesToLibraryAndSelectsPromotedSource() async throws {
        let nativeItem = makeItem(sourceKey: "alpha", displayName: "Alpha")
        let promotedItem = makeItem(
            sourceKey: "library-alpha",
            displayName: "Alpha",
            sourceMode: "library",
            primaryTool: "pnevma",
            primaryScope: "library",
            installs: [
                makeInstall(
                    path: "/Users/test/.config/pnevma/harness-library/skill/alpha/SKILL.md",
                    rootPath: "/Users/test/.config/pnevma/harness-library/skill/alpha",
                    tool: "pnevma",
                    scope: "library"
                ),
                makeInstall(
                    path: "/tmp/Alpha/SKILL.md",
                    rootPath: "/tmp/Alpha",
                    tool: "codex",
                    scope: "user",
                    backingMode: "copy",
                    status: "ok",
                    removalPolicy: "forget_only"
                )
            ]
        )
        let installPlan = HarnessInstallPlan(
            sourceMode: "library",
            sourcePath: promotedItem.primaryPath,
            sourceRootPath: promotedItem.primaryRootPath,
            sourceKey: promotedItem.sourceKey,
            slug: "alpha",
            requiresPromotion: true,
            operations: [
                HarnessPlannedOperation(
                    action: "promote_source",
                    path: promotedItem.primaryPath,
                    tool: "pnevma",
                    scope: "library",
                    backingMode: "source",
                    conflict: nil,
                    note: "Promotes into library"
                )
            ],
            warnings: []
        )
        let installResult = HarnessMutationResult(
            sourceKey: promotedItem.sourceKey,
            sourcePath: promotedItem.primaryPath,
            sourceRootPath: promotedItem.primaryRootPath,
            warnings: ["Promoted"]
        )
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [nativeItem]), makeSnapshot(items: [promotedItem])],
            readResponses: [
                promotedItem.sourceKey: HarnessCatalogReadContent(
                    sourceKey: promotedItem.sourceKey,
                    content: "# Alpha\n",
                    format: "markdown",
                    path: promotedItem.primaryPath
                )
            ],
            installPlanResponse: installPlan,
            installResult: installResult
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()

        let plan = await viewModel.planInstallItem(
            sourceKey: nativeItem.sourceKey,
            targets: [HarnessTargetParams(tool: "claude", scope: "user")],
            replaceExisting: false
        )
        XCTAssertEqual(plan?.requiresPromotion, true)

        let result = await viewModel.installItem(
            sourceKey: nativeItem.sourceKey,
            targets: [HarnessTargetParams(tool: "claude", scope: "user")],
            replaceExisting: false,
            allowCopyFallback: true
        )
        XCTAssertEqual(result?.sourceKey, promotedItem.sourceKey)

        try await waitUntil {
            viewModel.selectedSourceKey == promotedItem.sourceKey
        }
    }

    func testReinstallInstallReusesSingleTargetWithReplaceExisting() async throws {
        let libraryItem = makeItem(
            sourceKey: "library-alpha",
            displayName: "Alpha",
            sourceMode: "library",
            primaryTool: "pnevma",
            primaryScope: "library",
            installs: [
                makeInstall(
                    path: "/Users/test/.config/pnevma/harness-library/skill/alpha/SKILL.md",
                    rootPath: "/Users/test/.config/pnevma/harness-library/skill/alpha",
                    tool: "pnevma",
                    scope: "library"
                ),
                makeInstall(
                    path: "/Users/test/.claude/skills/alpha/SKILL.md",
                    rootPath: "/Users/test/.claude/skills/alpha",
                    tool: "claude",
                    scope: "user",
                    backingMode: "symlink",
                    status: "missing",
                    removalPolicy: "delete_target"
                ),
            ]
        )
        let installResult = HarnessMutationResult(
            sourceKey: libraryItem.sourceKey,
            sourcePath: libraryItem.primaryPath,
            sourceRootPath: libraryItem.primaryRootPath,
            warnings: []
        )
        let bus = HarnessCatalogCommandBusStub(
            snapshotResponses: [makeSnapshot(items: [libraryItem]), makeSnapshot(items: [libraryItem])],
            readResponses: [
                libraryItem.sourceKey: HarnessCatalogReadContent(
                    sourceKey: libraryItem.sourceKey,
                    content: "# Alpha\n",
                    format: "markdown",
                    path: libraryItem.primaryPath
                )
            ],
            installResult: installResult
        )
        let viewModel = HarnessConfigViewModel(commandBus: bus, bridgeEventHub: BridgeEventHub())
        await viewModel.activate()

        guard let reinstallTarget = libraryItem.installs.first(where: { $0.removalPolicy == "delete_target" }) else {
            return XCTFail("expected reinstallable install")
        }

        viewModel.reinstallInstall(reinstallTarget, from: libraryItem)

        try await waitUntil {
            let installs = await bus.installs()
            return installs.count == 1
        }

        let installs = await bus.installs()
        XCTAssertEqual(installs.first?.sourceKey, libraryItem.sourceKey)
        XCTAssertEqual(installs.first?.replaceExisting, true)
        XCTAssertEqual(installs.first?.allowCopyFallback, true)
        XCTAssertEqual(
            installs.first?.targets,
            [HarnessTargetParams(tool: "claude", scope: "user")]
        )
    }
}
