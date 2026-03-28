use super::*;
use pnevma_db::{
    sha256_hex, HarnessCollectionItemRow, HarnessCollectionRow, HarnessInstallRecordRow,
    HarnessScanRootRow,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::ffi::OsStr;
use tracing::debug;

const HARNESS_UPDATED_EVENT: &str = "harness_catalog_updated";
const SUPPORT_FILE_LIMIT: usize = 64;
const HEAVY_ITEM_BYTES: usize = 5_000;
const LIBRARY_TOOL: &str = "pnevma";
const LIBRARY_SCOPE: &str = "library";
const LIBRARY_ROOT_REL: &str = ".config/pnevma/harness-library";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessInstallView {
    pub path: String,
    pub root_path: String,
    pub tool: String,
    pub scope: String,
    pub format: String,
    pub exists: bool,
    pub backing_mode: String,
    pub status: String,
    pub removal_policy: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessSupportFileView {
    pub rel_path: String,
    pub path: String,
    pub format: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCatalogItemView {
    pub source_key: String,
    pub display_name: String,
    pub summary: Option<String>,
    pub kind: String,
    pub source_mode: String,
    pub primary_tool: String,
    pub primary_scope: String,
    pub tools: Vec<String>,
    pub scopes: Vec<String>,
    pub format: String,
    pub primary_path: String,
    pub primary_root_path: String,
    pub canonical_path: String,
    pub exists: bool,
    pub folder_backed: bool,
    pub size_bytes: u64,
    pub install_count: usize,
    pub support_file_count: usize,
    pub is_favorite: bool,
    pub collections: Vec<String>,
    pub is_heavy: bool,
    pub installs: Vec<HarnessInstallView>,
    pub support_files: Vec<HarnessSupportFileView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCollectionView {
    pub id: String,
    pub name: String,
    pub item_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCatalogReadView {
    pub source_key: String,
    pub content: String,
    pub format: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessScanRootView {
    pub id: String,
    pub path: String,
    pub label: Option<String>,
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCountView {
    pub key: String,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCatalogAnalyticsView {
    pub total_items: usize,
    pub favorite_count: usize,
    pub collection_count: usize,
    pub folder_backed_count: usize,
    pub heavy_count: usize,
    pub by_kind: Vec<HarnessCountView>,
    pub by_tool: Vec<HarnessCountView>,
    pub by_scope: Vec<HarnessCountView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessTargetOptionView {
    pub tool: String,
    pub scope: String,
    pub enabled: bool,
    pub reason_disabled: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCreatableKindView {
    pub kind: String,
    pub default_primary_file: String,
    pub default_format: String,
    pub allowed_targets: Vec<HarnessTargetOptionView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCatalogCapabilitiesView {
    pub library_root_path: String,
    pub creatable_kinds: Vec<HarnessCreatableKindView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCatalogSnapshotView {
    pub items: Vec<HarnessCatalogItemView>,
    pub collections: Vec<HarnessCollectionView>,
    pub scan_roots: Vec<HarnessScanRootView>,
    pub analytics: HarnessCatalogAnalyticsView,
    pub capabilities: HarnessCatalogCapabilitiesView,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessPlannedOperationView {
    pub action: String,
    pub path: String,
    pub tool: String,
    pub scope: String,
    pub backing_mode: String,
    pub conflict: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessCreatePlanView {
    pub source_mode: String,
    pub source_path: String,
    pub source_root_path: String,
    pub slug: String,
    pub template_content: String,
    pub operations: Vec<HarnessPlannedOperationView>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessInstallPlanView {
    pub source_mode: String,
    pub source_path: String,
    pub source_root_path: String,
    pub source_key: Option<String>,
    pub slug: String,
    pub requires_promotion: bool,
    pub operations: Vec<HarnessPlannedOperationView>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarnessMutationResultView {
    pub source_key: String,
    pub source_path: String,
    pub source_root_path: String,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReadHarnessCatalogItemInput {
    pub source_key: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteHarnessCatalogItemInput {
    pub source_key: String,
    pub content: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ToggleHarnessFavoriteInput {
    pub source_key: String,
    pub favorite: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateHarnessCollectionInput {
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RenameHarnessCollectionInput {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetHarnessCollectionMembershipInput {
    pub collection_id: String,
    pub source_key: String,
    pub present: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpsertHarnessScanRootInput {
    pub path: String,
    pub label: Option<String>,
    pub enabled: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetHarnessScanRootEnabledInput {
    pub id: String,
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DeleteHarnessScanRootInput {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HarnessTargetInput {
    pub tool: String,
    pub scope: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanCreateHarnessItemInput {
    pub kind: String,
    pub name: String,
    #[serde(default)]
    pub targets: Vec<HarnessTargetInput>,
    #[serde(default)]
    pub replace_existing: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApplyCreateHarnessItemInput {
    pub kind: String,
    pub name: String,
    #[serde(default)]
    pub slug: Option<String>,
    pub content: String,
    #[serde(default)]
    pub targets: Vec<HarnessTargetInput>,
    #[serde(default)]
    pub replace_existing: Option<bool>,
    #[serde(default)]
    pub allow_copy_fallback: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PlanInstallHarnessItemInput {
    pub source_key: String,
    #[serde(default)]
    pub targets: Vec<HarnessTargetInput>,
    #[serde(default)]
    pub replace_existing: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ApplyInstallHarnessItemInput {
    pub source_key: String,
    #[serde(default)]
    pub targets: Vec<HarnessTargetInput>,
    #[serde(default)]
    pub replace_existing: Option<bool>,
    #[serde(default)]
    pub allow_copy_fallback: Option<bool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RemoveHarnessInstallInput {
    pub source_key: String,
    pub target_path: String,
}

#[derive(Debug, Clone)]
struct DiscoveredInstall {
    display_name: String,
    summary: Option<String>,
    kind: String,
    tool: String,
    scope: String,
    format: String,
    path: PathBuf,
    root_path: PathBuf,
    canonical_path: PathBuf,
    canonical_root_path: PathBuf,
    folder_backed: bool,
    size_bytes: u64,
    support_files: Vec<HarnessSupportFileView>,
}

#[derive(Debug, Clone)]
struct CatalogMeta {
    favorites: HashSet<String>,
    collection_rows: Vec<HarnessCollectionRow>,
    collection_items: Vec<HarnessCollectionItemRow>,
    collections_by_source_key: HashMap<String, Vec<String>>,
    scan_roots: Vec<HarnessScanRootRow>,
    install_records: Vec<HarnessInstallRecordRow>,
}

#[derive(Debug)]
struct AggregatedItem {
    source_key: String,
    display_name: String,
    summary: Option<String>,
    kind: String,
    source_mode: String,
    primary_tool: String,
    primary_scope: String,
    tools: BTreeSet<String>,
    scopes: BTreeSet<String>,
    format: String,
    primary_path: String,
    primary_root_path: String,
    canonical_path: String,
    exists: bool,
    folder_backed: bool,
    size_bytes: u64,
    installs: Vec<HarnessInstallView>,
    support_files: BTreeMap<String, HarnessSupportFileView>,
    has_canonical_source: bool,
}

#[derive(Debug, Clone)]
struct CatalogContext {
    home: PathBuf,
    project_root: Option<PathBuf>,
    library_root: PathBuf,
}

#[derive(Debug, Clone)]
struct ResolvedTarget {
    tool: String,
    scope: String,
    kind: String,
    format: String,
    primary_path: PathBuf,
    root_path: PathBuf,
    folder_backed: bool,
}

pub async fn snapshot_harness_catalog(
    state: &AppState,
) -> Result<HarnessCatalogSnapshotView, String> {
    load_catalog_snapshot(state).await
}

pub async fn list_harness_catalog_items(
    state: &AppState,
) -> Result<Vec<HarnessCatalogItemView>, String> {
    Ok(load_catalog_snapshot(state).await?.items)
}

pub async fn read_harness_catalog_item(
    input: ReadHarnessCatalogItemInput,
    state: &AppState,
) -> Result<HarnessCatalogReadView, String> {
    let item = find_catalog_item(&input.source_key, state).await?;
    let content = tokio::fs::read_to_string(&item.primary_path)
        .await
        .map_err(|e| format!("failed to read {}: {e}", item.primary_path))?;
    Ok(HarnessCatalogReadView {
        source_key: item.source_key,
        content,
        format: item.format,
        path: item.primary_path,
    })
}

pub async fn write_harness_catalog_item(
    input: WriteHarnessCatalogItemInput,
    state: &AppState,
) -> Result<Value, String> {
    let item = find_catalog_item(&input.source_key, state).await?;
    validate_content(&input.content, &item.format)?;
    let path = PathBuf::from(&item.primary_path);
    create_backup(&path, &input.source_key)?;

    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("failed to create parent directory: {e}"))?;
    }

    let temp_path = path.with_extension(format!(
        "{}.tmp",
        path.extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("write")
    ));

    if let Err(err) = tokio::fs::write(&temp_path, &input.content).await {
        let _ = tokio::fs::remove_file(&temp_path).await;
        return Err(format!("failed to write temp file: {err}"));
    }
    if let Err(err) = tokio::fs::rename(&temp_path, &path).await {
        let _ = tokio::fs::remove_file(&temp_path).await;
        return Err(format!("failed to replace file: {err}"));
    }

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "item_written",
            "source_key": input.source_key,
            "path": item.primary_path,
            "kind": item.kind,
        }),
    );

    Ok(json!({
        "ok": true,
        "path": item.primary_path,
    }))
}

pub async fn toggle_harness_favorite(
    input: ToggleHarnessFavoriteInput,
    state: &AppState,
) -> Result<Value, String> {
    let global_db = state.global_db()?;
    let current = list_harness_catalog_items(state).await?;
    let is_currently_favorite = current
        .iter()
        .find(|item| item.source_key == input.source_key)
        .map(|item| item.is_favorite)
        .unwrap_or(false);
    let favorite = input.favorite.unwrap_or(!is_currently_favorite);
    global_db
        .set_harness_favorite(&input.source_key, favorite)
        .await
        .map_err(|e| e.to_string())?;

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "favorite_toggled",
            "source_key": input.source_key,
            "favorite": favorite,
        }),
    );

    Ok(json!({ "ok": true, "favorite": favorite }))
}

pub async fn list_harness_collections(
    state: &AppState,
) -> Result<Vec<HarnessCollectionView>, String> {
    Ok(load_catalog_snapshot(state).await?.collections)
}

pub async fn create_harness_collection(
    input: CreateHarnessCollectionInput,
    state: &AppState,
) -> Result<HarnessCollectionView, String> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err("collection name is required".to_string());
    }
    let global_db = state.global_db()?;
    let now = Utc::now();
    let row = HarnessCollectionRow {
        id: Uuid::new_v4().to_string(),
        name: name.to_string(),
        created_at: now,
        updated_at: now,
    };
    global_db
        .create_harness_collection(&row)
        .await
        .map_err(|e| e.to_string())?;

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "collection_created",
            "collection_id": row.id,
            "name": row.name,
        }),
    );

    Ok(HarnessCollectionView {
        id: row.id,
        name: row.name,
        item_count: 0,
    })
}

pub async fn rename_harness_collection(
    input: RenameHarnessCollectionInput,
    state: &AppState,
) -> Result<Value, String> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err("collection name is required".to_string());
    }
    let global_db = state.global_db()?;
    global_db
        .rename_harness_collection(&input.id, name)
        .await
        .map_err(|e| e.to_string())?;
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "collection_renamed",
            "collection_id": input.id,
            "name": name,
        }),
    );
    Ok(json!({ "ok": true }))
}

pub async fn delete_harness_collection(id: String, state: &AppState) -> Result<(), String> {
    let global_db = state.global_db()?;
    global_db
        .delete_harness_collection(&id)
        .await
        .map_err(|e| e.to_string())?;
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({ "reason": "collection_deleted", "collection_id": id }),
    );
    Ok(())
}

pub async fn set_harness_collection_membership(
    input: SetHarnessCollectionMembershipInput,
    state: &AppState,
) -> Result<Value, String> {
    let global_db = state.global_db()?;
    if input.present {
        global_db
            .add_harness_collection_item(&input.collection_id, &input.source_key)
            .await
            .map_err(|e| e.to_string())?;
    } else {
        global_db
            .remove_harness_collection_item(&input.collection_id, &input.source_key)
            .await
            .map_err(|e| e.to_string())?;
    }
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "collection_membership_updated",
            "collection_id": input.collection_id,
            "source_key": input.source_key,
            "present": input.present,
        }),
    );
    Ok(json!({ "ok": true }))
}

pub async fn list_harness_scan_roots(state: &AppState) -> Result<Vec<HarnessScanRootView>, String> {
    Ok(load_catalog_snapshot(state).await?.scan_roots)
}

pub async fn upsert_harness_scan_root(
    input: UpsertHarnessScanRootInput,
    state: &AppState,
) -> Result<HarnessScanRootView, String> {
    let path = expand_home_path(input.path.trim())?;
    let canonical_path = normalize_discoverable_root(&path)?;
    let global_db = state.global_db()?;
    let now = Utc::now();
    let row = HarnessScanRootRow {
        id: Uuid::new_v4().to_string(),
        path: canonical_path.to_string_lossy().to_string(),
        label: input.label.filter(|value| !value.trim().is_empty()),
        enabled: input.enabled.unwrap_or(true),
        created_at: now,
        updated_at: now,
    };
    let stored = global_db
        .upsert_harness_scan_root(&row)
        .await
        .map_err(|e| e.to_string())?;
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "scan_root_upserted",
            "scan_root_id": stored.id,
            "path": stored.path,
            "enabled": stored.enabled,
        }),
    );
    Ok(HarnessScanRootView {
        id: stored.id,
        path: stored.path,
        label: stored.label,
        enabled: stored.enabled,
    })
}

pub async fn set_harness_scan_root_enabled(
    input: SetHarnessScanRootEnabledInput,
    state: &AppState,
) -> Result<Value, String> {
    let global_db = state.global_db()?;
    global_db
        .set_harness_scan_root_enabled(&input.id, input.enabled)
        .await
        .map_err(|e| e.to_string())?;
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "scan_root_enabled_changed",
            "scan_root_id": input.id,
            "enabled": input.enabled,
        }),
    );
    Ok(json!({ "ok": true }))
}

pub async fn delete_harness_scan_root(
    input: DeleteHarnessScanRootInput,
    state: &AppState,
) -> Result<(), String> {
    let global_db = state.global_db()?;
    global_db
        .delete_harness_scan_root(&input.id)
        .await
        .map_err(|e| e.to_string())?;
    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "scan_root_deleted",
            "scan_root_id": input.id,
        }),
    );
    Ok(())
}

pub async fn get_harness_catalog_analytics(
    state: &AppState,
) -> Result<HarnessCatalogAnalyticsView, String> {
    Ok(load_catalog_snapshot(state).await?.analytics)
}

pub async fn plan_create_harness_item(
    input: PlanCreateHarnessItemInput,
    state: &AppState,
) -> Result<HarnessCreatePlanView, String> {
    let context = catalog_context(state).await?;
    let targets = validate_targets(&input.kind, &input.targets, &context)?;
    let name = input.name.trim();
    if name.is_empty() {
        return Err("name is required".to_string());
    }
    let slug = unique_slug_for_create(&input.kind, slugify(name), &targets, &context)?;
    let template_content = default_template_for_kind(&input.kind, name)?;
    let replace_existing = input.replace_existing.unwrap_or(false);

    if targets.len() == 1 {
        let target = &targets[0];
        let conflict = conflict_for_target(target, replace_existing);
        return Ok(HarnessCreatePlanView {
            source_mode: "native".to_string(),
            source_path: target.primary_path.to_string_lossy().to_string(),
            source_root_path: target.root_path.to_string_lossy().to_string(),
            slug,
            template_content,
            operations: vec![HarnessPlannedOperationView {
                action: "write_source".to_string(),
                path: target.primary_path.to_string_lossy().to_string(),
                tool: target.tool.clone(),
                scope: target.scope.clone(),
                backing_mode: "source".to_string(),
                conflict,
                note: None,
            }],
            warnings: vec![],
        });
    }

    let source = resolve_library_target(&input.kind, &slug, &context)?;
    let mut operations = vec![HarnessPlannedOperationView {
        action: "write_source".to_string(),
        path: source.primary_path.to_string_lossy().to_string(),
        tool: LIBRARY_TOOL.to_string(),
        scope: LIBRARY_SCOPE.to_string(),
        backing_mode: "source".to_string(),
        conflict: conflict_for_target(&source, replace_existing),
        note: None,
    }];
    for target in &targets {
        operations.push(HarnessPlannedOperationView {
            action: "install".to_string(),
            path: target.root_path.to_string_lossy().to_string(),
            tool: target.tool.clone(),
            scope: target.scope.clone(),
            backing_mode: "symlink".to_string(),
            conflict: conflict_for_target(target, replace_existing),
            note: Some(
                "Will fall back to copy if symlink creation fails and copy fallback is enabled."
                    .to_string(),
            ),
        });
    }

    Ok(HarnessCreatePlanView {
        source_mode: "library".to_string(),
        source_path: source.primary_path.to_string_lossy().to_string(),
        source_root_path: source.root_path.to_string_lossy().to_string(),
        slug,
        template_content,
        operations,
        warnings: vec![],
    })
}

pub async fn apply_create_harness_item(
    input: ApplyCreateHarnessItemInput,
    state: &AppState,
) -> Result<HarnessMutationResultView, String> {
    let context = catalog_context(state).await?;
    let name = input.name.trim();
    if name.is_empty() {
        return Err("name is required".to_string());
    }
    validate_content(&input.content, "markdown")?;
    let targets = validate_targets(&input.kind, &input.targets, &context)?;
    let replace_existing = input.replace_existing.unwrap_or(false);
    let allow_copy_fallback = input.allow_copy_fallback.unwrap_or(true);
    let requested_slug = input
        .slug
        .as_deref()
        .map(slugify)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| slugify(name));
    let slug = unique_slug_for_create(&input.kind, requested_slug, &targets, &context)?;

    if targets.len() == 1 {
        let target = &targets[0];
        prepare_target_for_write(target, replace_existing)?;
        write_primary_file(target, &input.content).await?;
        let source_key = sha256_hex(target.primary_path.to_string_lossy().as_bytes());
        state.emitter.emit(
            HARNESS_UPDATED_EVENT,
            json!({
                "reason": "item_created",
                "source_key": source_key,
                "path": target.primary_path,
                "kind": input.kind,
            }),
        );
        return Ok(HarnessMutationResultView {
            source_key,
            source_path: target.primary_path.to_string_lossy().to_string(),
            source_root_path: target.root_path.to_string_lossy().to_string(),
            warnings: vec![],
        });
    }

    let source = resolve_library_target(&input.kind, &slug, &context)?;
    prepare_target_for_write(&source, replace_existing)?;
    write_primary_file(&source, &input.content).await?;
    let source_key = sha256_hex(source.primary_path.to_string_lossy().as_bytes());
    let source_fingerprint = fingerprint_item(&source.root_path, source.folder_backed)?;
    let global_db = state.global_db()?;
    let now = Utc::now();
    let mut warnings = Vec::new();

    for target in &targets {
        install_target(
            global_db,
            &source_key,
            &source,
            target,
            replace_existing,
            allow_copy_fallback,
            &source_fingerprint,
            &mut warnings,
            now,
            false,
        )
        .await?;
    }

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "item_created",
            "source_key": source_key,
            "path": source.primary_path,
            "kind": input.kind,
            "installs": targets.len(),
        }),
    );

    Ok(HarnessMutationResultView {
        source_key,
        source_path: source.primary_path.to_string_lossy().to_string(),
        source_root_path: source.root_path.to_string_lossy().to_string(),
        warnings,
    })
}

pub async fn plan_install_harness_item(
    input: PlanInstallHarnessItemInput,
    state: &AppState,
) -> Result<HarnessInstallPlanView, String> {
    let context = catalog_context(state).await?;
    let item = find_catalog_item(&input.source_key, state).await?;
    let targets = validate_targets(&item.kind, &input.targets, &context)?;
    let replace_existing = input.replace_existing.unwrap_or(false);
    let requires_promotion = item.source_mode != "library";
    let slug = slugify(&item.display_name);
    let source = if requires_promotion {
        resolve_library_target(
            &item.kind,
            &unique_slug_for_library(&item.kind, slug, &context)?,
            &context,
        )?
    } else {
        resolve_item_as_source(&item)?
    };

    let mut operations = Vec::new();
    if requires_promotion {
        operations.push(HarnessPlannedOperationView {
            action: "promote_source".to_string(),
            path: source.primary_path.to_string_lossy().to_string(),
            tool: LIBRARY_TOOL.to_string(),
            scope: LIBRARY_SCOPE.to_string(),
            backing_mode: "source".to_string(),
            conflict: conflict_for_target(&source, replace_existing),
            note: Some(
                "The original source stays on disk and is adopted as a forget-only install."
                    .to_string(),
            ),
        });
    }
    for target in &targets {
        operations.push(HarnessPlannedOperationView {
            action: "install".to_string(),
            path: target.root_path.to_string_lossy().to_string(),
            tool: target.tool.clone(),
            scope: target.scope.clone(),
            backing_mode: "symlink".to_string(),
            conflict: conflict_for_target(target, replace_existing),
            note: Some(
                "Will fall back to copy if symlink creation fails and copy fallback is enabled."
                    .to_string(),
            ),
        });
    }

    Ok(HarnessInstallPlanView {
        source_mode: "library".to_string(),
        source_path: source.primary_path.to_string_lossy().to_string(),
        source_root_path: source.root_path.to_string_lossy().to_string(),
        source_key: Some(sha256_hex(source.primary_path.to_string_lossy().as_bytes())),
        slug: source
            .root_path
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or_default()
            .to_string(),
        requires_promotion,
        operations,
        warnings: vec![],
    })
}

pub async fn apply_install_harness_item(
    input: ApplyInstallHarnessItemInput,
    state: &AppState,
) -> Result<HarnessMutationResultView, String> {
    let context = catalog_context(state).await?;
    let item = find_catalog_item(&input.source_key, state).await?;
    let targets = validate_targets(&item.kind, &input.targets, &context)?;
    let replace_existing = input.replace_existing.unwrap_or(false);
    let allow_copy_fallback = input.allow_copy_fallback.unwrap_or(true);
    let global_db = state.global_db()?;
    let now = Utc::now();
    let mut warnings = Vec::new();

    let (source_key, source) = if item.source_mode == "library" {
        (item.source_key.clone(), resolve_item_as_source(&item)?)
    } else {
        let slug = unique_slug_for_library(&item.kind, slugify(&item.display_name), &context)?;
        let library_source = resolve_library_target(&item.kind, &slug, &context)?;
        prepare_target_for_write(&library_source, replace_existing)?;
        copy_item_root(
            &PathBuf::from(&item.primary_root_path),
            &PathBuf::from(&item.primary_path),
            &library_source.root_path,
            &library_source.primary_path,
            item.folder_backed,
        )?;
        let promoted_source_key =
            sha256_hex(library_source.primary_path.to_string_lossy().as_bytes());
        let promoted_fingerprint =
            fingerprint_item(&library_source.root_path, library_source.folder_backed)?;
        let adopt_row = HarnessInstallRecordRow {
            id: Uuid::new_v4().to_string(),
            source_key: promoted_source_key.clone(),
            source_path: library_source.primary_path.to_string_lossy().to_string(),
            source_root_path: library_source.root_path.to_string_lossy().to_string(),
            target_path: item.primary_path.clone(),
            target_root_path: item.primary_root_path.clone(),
            tool: item.primary_tool.clone(),
            scope: item.primary_scope.clone(),
            backing_mode: "copy".to_string(),
            removal_policy: "forget_only".to_string(),
            last_synced_fingerprint: Some(promoted_fingerprint.clone()),
            created_at: now,
            updated_at: now,
        };
        global_db
            .upsert_harness_install_record(&adopt_row)
            .await
            .map_err(|e| e.to_string())?;
        warnings.push(
            "Promoted item into the Pnevma harness library before installing additional targets."
                .to_string(),
        );
        (promoted_source_key, library_source)
    };

    let source_fingerprint = fingerprint_item(&source.root_path, source.folder_backed)?;
    for target in &targets {
        install_target(
            global_db,
            &source_key,
            &source,
            target,
            replace_existing,
            allow_copy_fallback,
            &source_fingerprint,
            &mut warnings,
            now,
            false,
        )
        .await?;
    }

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "item_installed",
            "source_key": source_key,
            "path": source.primary_path,
            "installs": targets.len(),
        }),
    );

    Ok(HarnessMutationResultView {
        source_key,
        source_path: source.primary_path.to_string_lossy().to_string(),
        source_root_path: source.root_path.to_string_lossy().to_string(),
        warnings,
    })
}

pub async fn remove_harness_install(
    input: RemoveHarnessInstallInput,
    state: &AppState,
) -> Result<Value, String> {
    let global_db = state.global_db()?;
    let records = global_db
        .list_harness_install_records()
        .await
        .map_err(|e| e.to_string())?;
    let record = records
        .into_iter()
        .find(|row| row.source_key == input.source_key && row.target_path == input.target_path)
        .ok_or_else(|| format!("install record not found: {}", input.target_path))?;

    if record.removal_policy == "delete_target" {
        remove_path_safe(
            Path::new(&record.target_root_path),
            Path::new(&record.target_path),
        )?;
    }
    global_db
        .delete_harness_install_record_by_target_path(&record.target_path)
        .await
        .map_err(|e| e.to_string())?;

    state.emitter.emit(
        HARNESS_UPDATED_EVENT,
        json!({
            "reason": "install_removed",
            "source_key": input.source_key,
            "target_path": input.target_path,
            "removal_policy": record.removal_policy,
        }),
    );
    Ok(json!({ "ok": true }))
}

async fn load_catalog_snapshot(state: &AppState) -> Result<HarnessCatalogSnapshotView, String> {
    let meta = load_catalog_meta(state).await?;
    let context = catalog_context(state).await?;
    let discovered = discover_catalog_items(&context, &meta.scan_roots)?;
    let items = aggregate_catalog_items(discovered, &meta, &context)?;
    let collections = build_collection_views(&meta, &items);
    let scan_roots = meta
        .scan_roots
        .iter()
        .map(|row| HarnessScanRootView {
            id: row.id.clone(),
            path: row.path.clone(),
            label: row.label.clone(),
            enabled: row.enabled,
        })
        .collect::<Vec<_>>();
    let analytics = build_analytics(&items, collections.len());
    let capabilities = build_capabilities(&context);

    Ok(HarnessCatalogSnapshotView {
        items,
        collections,
        scan_roots,
        analytics,
        capabilities,
    })
}

async fn find_catalog_item(
    source_key: &str,
    state: &AppState,
) -> Result<HarnessCatalogItemView, String> {
    load_catalog_snapshot(state)
        .await?
        .items
        .into_iter()
        .find(|item| item.source_key == source_key)
        .ok_or_else(|| format!("harness item not found: {source_key}"))
}

async fn load_catalog_meta(state: &AppState) -> Result<CatalogMeta, String> {
    let Ok(global_db) = state.global_db() else {
        return Ok(CatalogMeta {
            favorites: HashSet::new(),
            collection_rows: Vec::new(),
            collection_items: Vec::new(),
            collections_by_source_key: HashMap::new(),
            scan_roots: Vec::new(),
            install_records: Vec::new(),
        });
    };

    let favorites = global_db
        .list_harness_favorites()
        .await
        .map_err(|e| e.to_string())?;
    let collection_rows = global_db
        .list_harness_collections()
        .await
        .map_err(|e| e.to_string())?;
    let collection_items = global_db
        .list_harness_collection_items()
        .await
        .map_err(|e| e.to_string())?;
    let scan_roots = global_db
        .list_harness_scan_roots()
        .await
        .map_err(|e| e.to_string())?;
    let install_records = global_db
        .list_harness_install_records()
        .await
        .map_err(|e| e.to_string())?;

    let favorite_keys = favorites
        .into_iter()
        .map(|row| row.source_key)
        .collect::<HashSet<_>>();

    let collection_names = collection_rows
        .iter()
        .map(|row| (row.id.clone(), row.name.clone()))
        .collect::<HashMap<_, _>>();

    let mut collections_by_source_key = HashMap::<String, Vec<String>>::new();
    for HarnessCollectionItemRow {
        collection_id,
        source_key,
        ..
    } in &collection_items
    {
        if let Some(name) = collection_names.get(collection_id) {
            collections_by_source_key
                .entry(source_key.clone())
                .or_default()
                .push(name.clone());
        }
    }
    for names in collections_by_source_key.values_mut() {
        names.sort();
        names.dedup();
    }

    Ok(CatalogMeta {
        favorites: favorite_keys,
        collection_rows,
        collection_items,
        collections_by_source_key,
        scan_roots,
        install_records,
    })
}

async fn catalog_context(state: &AppState) -> Result<CatalogContext, String> {
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| "HOME environment variable not set".to_string())?;
    let library_root = home.join(LIBRARY_ROOT_REL);
    let project_root = state
        .with_project("harness_catalog.project_root", |ctx| {
            ctx.checkout_path.clone()
        })
        .await
        .ok();
    Ok(CatalogContext {
        home,
        project_root,
        library_root,
    })
}

fn build_collection_views(
    meta: &CatalogMeta,
    items: &[HarnessCatalogItemView],
) -> Vec<HarnessCollectionView> {
    let live_keys = items
        .iter()
        .map(|item| item.source_key.clone())
        .collect::<HashSet<_>>();
    let mut counts = HashMap::<String, usize>::new();
    for row in &meta.collection_items {
        if live_keys.contains(&row.source_key) {
            *counts.entry(row.collection_id.clone()).or_default() += 1;
        }
    }
    meta.collection_rows
        .iter()
        .map(|row| HarnessCollectionView {
            id: row.id.clone(),
            name: row.name.clone(),
            item_count: counts.get(&row.id).copied().unwrap_or(0),
        })
        .collect()
}

fn build_analytics(
    items: &[HarnessCatalogItemView],
    collection_count: usize,
) -> HarnessCatalogAnalyticsView {
    let favorite_count = items.iter().filter(|item| item.is_favorite).count();
    let folder_backed_count = items.iter().filter(|item| item.folder_backed).count();
    let heavy_count = items.iter().filter(|item| item.is_heavy).count();

    HarnessCatalogAnalyticsView {
        total_items: items.len(),
        favorite_count,
        collection_count,
        folder_backed_count,
        heavy_count,
        by_kind: count_by(items.iter().map(|item| item.kind.clone())),
        by_tool: count_by(items.iter().flat_map(|item| item.tools.clone())),
        by_scope: count_by(items.iter().flat_map(|item| item.scopes.clone())),
    }
}

fn count_by(values: impl Iterator<Item = String>) -> Vec<HarnessCountView> {
    let mut counts = BTreeMap::<String, usize>::new();
    for value in values {
        *counts.entry(value).or_default() += 1;
    }
    counts
        .into_iter()
        .map(|(key, count)| HarnessCountView { key, count })
        .collect()
}

fn build_capabilities(context: &CatalogContext) -> HarnessCatalogCapabilitiesView {
    let project_available = context.project_root.is_some();
    HarnessCatalogCapabilitiesView {
        library_root_path: context.library_root.to_string_lossy().to_string(),
        creatable_kinds: vec![
            HarnessCreatableKindView {
                kind: "skill".to_string(),
                default_primary_file: "SKILL.md".to_string(),
                default_format: "markdown".to_string(),
                allowed_targets: vec![
                    target_option("claude", "user", true, None),
                    target_option(
                        "claude",
                        "project",
                        project_available,
                        disabled_reason(project_available),
                    ),
                    target_option("codex", "user", true, None),
                    target_option(
                        "codex",
                        "project",
                        project_available,
                        disabled_reason(project_available),
                    ),
                    target_option("global", "global", true, None),
                ],
            },
            HarnessCreatableKindView {
                kind: "agent".to_string(),
                default_primary_file: "AGENTS.md".to_string(),
                default_format: "markdown".to_string(),
                allowed_targets: vec![
                    target_option("claude", "user", true, None),
                    target_option(
                        "claude",
                        "project",
                        project_available,
                        disabled_reason(project_available),
                    ),
                ],
            },
            HarnessCreatableKindView {
                kind: "command".to_string(),
                default_primary_file: "COMMAND.md".to_string(),
                default_format: "markdown".to_string(),
                allowed_targets: vec![
                    target_option("claude", "user", true, None),
                    target_option(
                        "claude",
                        "project",
                        project_available,
                        disabled_reason(project_available),
                    ),
                ],
            },
        ],
    }
}

fn disabled_reason(enabled: bool) -> Option<String> {
    if enabled {
        None
    } else {
        Some("Open a project to use project-scoped targets.".to_string())
    }
}

fn target_option(
    tool: &str,
    scope: &str,
    enabled: bool,
    reason_disabled: Option<String>,
) -> HarnessTargetOptionView {
    HarnessTargetOptionView {
        tool: tool.to_string(),
        scope: scope.to_string(),
        enabled,
        reason_disabled,
    }
}

fn discover_catalog_items(
    context: &CatalogContext,
    scan_roots: &[HarnessScanRootRow],
) -> Result<Vec<DiscoveredInstall>, String> {
    let mut items = Vec::new();
    let library_root = normalize_optional_root(&context.library_root);

    let claude_root = context.home.join(".claude");
    let codex_root = context.home.join(".codex");
    let agents_root = context.home.join(".agents");

    push_fixed_file(
        &mut items,
        claude_root.join("settings.json"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "settings",
        Some("Claude Settings"),
    );
    push_fixed_file(
        &mut items,
        claude_root.join("settings.local.json"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "settings",
        Some("Claude Settings (Local)"),
    );
    push_fixed_file(
        &mut items,
        claude_root.join(".mcp.json"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "mcp",
        Some("Claude MCP Servers"),
    );
    push_fixed_file(
        &mut items,
        claude_root.join("hooks.json"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "hook",
        Some("Claude Hooks"),
    );
    discover_items_in_root(
        &mut items,
        claude_root.join("skills"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "skill",
        &["SKILL.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        claude_root.join("agents"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "agent",
        &["AGENTS.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        claude_root.join("commands"),
        &[claude_root.clone(), context.library_root.clone()],
        "claude",
        "user",
        "command",
        &["COMMAND.md", "SKILL.md"],
        &["md"],
    );

    push_fixed_file(
        &mut items,
        codex_root.join("config.toml"),
        &[codex_root.clone(), context.library_root.clone()],
        "codex",
        "user",
        "settings",
        Some("Codex Config"),
    );
    discover_items_in_root(
        &mut items,
        codex_root.join("skills"),
        &[codex_root.clone(), context.library_root.clone()],
        "codex",
        "user",
        "skill",
        &["SKILL.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        codex_root.join("rules"),
        &[codex_root.clone(), context.library_root.clone()],
        "codex",
        "user",
        "rule",
        &["RULE.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        codex_root.join("memories"),
        &[codex_root.clone(), context.library_root.clone()],
        "codex",
        "user",
        "memory",
        &["MEMORY.md"],
        &["md"],
    );
    push_fixed_file(
        &mut items,
        codex_root.join("AGENTS.md"),
        &[codex_root.clone(), context.library_root.clone()],
        "codex",
        "user",
        "agent",
        Some("Codex AGENTS"),
    );

    discover_items_in_root(
        &mut items,
        agents_root.join("skills"),
        &[agents_root.clone(), context.library_root.clone()],
        "global",
        "global",
        "skill",
        &["SKILL.md"],
        &["md", "mdc", "toml"],
    );

    discover_items_in_root(
        &mut items,
        context.library_root.join("skill"),
        std::slice::from_ref(&context.library_root),
        LIBRARY_TOOL,
        LIBRARY_SCOPE,
        "skill",
        &["SKILL.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        context.library_root.join("agent"),
        std::slice::from_ref(&context.library_root),
        LIBRARY_TOOL,
        LIBRARY_SCOPE,
        "agent",
        &["AGENTS.md"],
        &["md", "mdc", "toml"],
    );
    discover_items_in_root(
        &mut items,
        context.library_root.join("command"),
        std::slice::from_ref(&context.library_root),
        LIBRARY_TOOL,
        LIBRARY_SCOPE,
        "command",
        &["COMMAND.md"],
        &["md", "mdc", "toml"],
    );

    if let Some(project_root) = &context.project_root {
        let project_claude = project_root.join(".claude");
        let project_codex = project_root.join(".codex");
        push_fixed_file(
            &mut items,
            project_claude.join("settings.local.json"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "settings",
            Some("Project Claude Settings"),
        );
        push_fixed_file(
            &mut items,
            project_claude.join("hooks.json"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "hook",
            Some("Project Claude Hooks"),
        );
        push_fixed_file(
            &mut items,
            project_claude.join("CLAUDE.md"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "instructions",
            Some("Project CLAUDE.md"),
        );
        discover_items_in_root(
            &mut items,
            project_claude.join("skills"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "skill",
            &["SKILL.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            &mut items,
            project_claude.join("agents"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "agent",
            &["AGENTS.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            &mut items,
            project_claude.join("commands"),
            &[project_root.clone(), context.library_root.clone()],
            "claude",
            "project",
            "command",
            &["COMMAND.md", "SKILL.md"],
            &["md"],
        );
        push_fixed_file(
            &mut items,
            project_root.join("AGENTS.md"),
            &[project_root.clone(), context.library_root.clone()],
            "codex",
            "project",
            "agent",
            Some("Repo AGENTS.md"),
        );
        push_fixed_file(
            &mut items,
            project_codex.join("AGENTS.md"),
            &[project_root.clone(), context.library_root.clone()],
            "codex",
            "project",
            "agent",
            Some("Project Codex AGENTS"),
        );
        discover_items_in_root(
            &mut items,
            project_codex.join("skills"),
            &[project_root.clone(), context.library_root.clone()],
            "codex",
            "project",
            "skill",
            &["SKILL.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            &mut items,
            project_codex.join("rules"),
            &[project_root.clone(), context.library_root.clone()],
            "codex",
            "project",
            "rule",
            &["RULE.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            &mut items,
            project_codex.join("memories"),
            &[project_root.clone(), context.library_root.clone()],
            "codex",
            "project",
            "memory",
            &["MEMORY.md"],
            &["md"],
        );

        let project_key = project_root.to_string_lossy().replace('/', "-");
        push_fixed_file(
            &mut items,
            context
                .home
                .join(format!(".claude/projects/{project_key}/memory/MEMORY.md")),
            &[
                context.home.join(".claude/projects"),
                context.library_root.clone(),
            ],
            "claude",
            "project",
            "memory",
            Some("Claude Project Memory"),
        );
    }

    for row in scan_roots.iter().filter(|row| row.enabled) {
        discover_custom_root(&mut items, Path::new(&row.path), &context.library_root)?;
    }

    if let Some(root) = library_root {
        debug!(library_root = %root.display(), "harness library root enabled");
    }

    Ok(items)
}

fn aggregate_catalog_items(
    discovered: Vec<DiscoveredInstall>,
    meta: &CatalogMeta,
    context: &CatalogContext,
) -> Result<Vec<HarnessCatalogItemView>, String> {
    let record_by_target = meta
        .install_records
        .iter()
        .map(|row| (row.target_path.clone(), row.clone()))
        .collect::<HashMap<_, _>>();
    let mut seen_records = HashSet::<String>::new();
    let mut aggregated = HashMap::<String, AggregatedItem>::new();

    for install in discovered {
        let path_string = install.path.to_string_lossy().to_string();
        let root_path_string = install.root_path.to_string_lossy().to_string();
        let canonical_string = install.canonical_path.to_string_lossy().to_string();
        let record = record_by_target.get(&path_string);
        let source_key = record
            .map(|row| row.source_key.clone())
            .unwrap_or_else(|| sha256_hex(canonical_string.as_bytes()));
        let source_path = record
            .map(|row| row.source_path.clone())
            .unwrap_or_else(|| canonical_string.clone());
        let is_canonical_source = path_string == source_path;
        let source_mode =
            if source_path.starts_with(&context.library_root.to_string_lossy().to_string()) {
                "library"
            } else {
                "native"
            }
            .to_string();
        let install_view = if let Some(row) = record {
            seen_records.insert(row.target_path.clone());
            HarnessInstallView {
                path: path_string.clone(),
                root_path: root_path_string.clone(),
                tool: install.tool.clone(),
                scope: install.scope.clone(),
                format: install.format.clone(),
                exists: true,
                backing_mode: row.backing_mode.clone(),
                status: status_for_record(row, &install),
                removal_policy: row.removal_policy.clone(),
            }
        } else {
            let symlink = symlink_metadata_is_symlink(&install.root_path)
                || symlink_metadata_is_symlink(&install.path);
            HarnessInstallView {
                path: path_string.clone(),
                root_path: root_path_string.clone(),
                tool: install.tool.clone(),
                scope: install.scope.clone(),
                format: install.format.clone(),
                exists: true,
                backing_mode: if is_canonical_source {
                    "source".to_string()
                } else if symlink {
                    "symlink".to_string()
                } else {
                    "copy".to_string()
                },
                status: if is_canonical_source {
                    "ok".to_string()
                } else {
                    "external".to_string()
                },
                removal_policy: "source".to_string(),
            }
        };

        let entry = aggregated
            .entry(source_key.clone())
            .or_insert_with(|| AggregatedItem {
                source_key: source_key.clone(),
                display_name: install.display_name.clone(),
                summary: install.summary.clone(),
                kind: install.kind.clone(),
                source_mode: source_mode.clone(),
                primary_tool: install.tool.clone(),
                primary_scope: install.scope.clone(),
                tools: BTreeSet::new(),
                scopes: BTreeSet::new(),
                format: install.format.clone(),
                primary_path: if is_canonical_source {
                    path_string.clone()
                } else {
                    source_path.clone()
                },
                primary_root_path: if is_canonical_source {
                    root_path_string.clone()
                } else {
                    record
                        .map(|row| row.source_root_path.clone())
                        .unwrap_or_else(|| {
                            install.canonical_root_path.to_string_lossy().to_string()
                        })
                },
                canonical_path: source_path.clone(),
                exists: true,
                folder_backed: install.folder_backed,
                size_bytes: install.size_bytes,
                installs: Vec::new(),
                support_files: BTreeMap::new(),
                has_canonical_source: is_canonical_source,
            });

        if is_canonical_source && !entry.has_canonical_source {
            entry.primary_tool = install.tool.clone();
            entry.primary_scope = install.scope.clone();
            entry.primary_path = path_string.clone();
            entry.primary_root_path = root_path_string.clone();
            entry.canonical_path = source_path.clone();
            entry.source_mode = source_mode.clone();
            entry.has_canonical_source = true;
            entry.format = install.format.clone();
        }

        entry.tools.insert(install.tool.clone());
        entry.scopes.insert(install.scope.clone());
        entry.folder_backed |= install.folder_backed;
        entry.size_bytes = entry.size_bytes.max(install.size_bytes);
        if entry.summary.is_none() && install.summary.is_some() {
            entry.summary = install.summary.clone();
        }
        if !entry
            .installs
            .iter()
            .any(|row| row.path == install_view.path)
        {
            entry.installs.push(install_view);
        }
        if is_canonical_source {
            for support in install.support_files {
                entry
                    .support_files
                    .entry(support.rel_path.clone())
                    .or_insert(support);
            }
        }
    }

    for record in &meta.install_records {
        if seen_records.contains(&record.target_path) {
            continue;
        }
        if let Some(entry) = aggregated.get_mut(&record.source_key) {
            if !entry
                .installs
                .iter()
                .any(|row| row.path == record.target_path)
            {
                entry.installs.push(HarnessInstallView {
                    path: record.target_path.clone(),
                    root_path: record.target_root_path.clone(),
                    tool: record.tool.clone(),
                    scope: record.scope.clone(),
                    format: entry.format.clone(),
                    exists: false,
                    backing_mode: record.backing_mode.clone(),
                    status: "missing".to_string(),
                    removal_policy: record.removal_policy.clone(),
                });
            }
        }
    }

    let mut items = aggregated
        .into_values()
        .map(|item| {
            let collections = meta
                .collections_by_source_key
                .get(&item.source_key)
                .cloned()
                .unwrap_or_default();
            let support_files = item.support_files.into_values().collect::<Vec<_>>();
            HarnessCatalogItemView {
                source_key: item.source_key.clone(),
                display_name: item.display_name,
                summary: item.summary,
                kind: item.kind,
                source_mode: item.source_mode,
                primary_tool: item.primary_tool,
                primary_scope: item.primary_scope,
                tools: item.tools.into_iter().collect(),
                scopes: item.scopes.into_iter().collect(),
                format: item.format,
                primary_path: item.primary_path,
                primary_root_path: item.primary_root_path,
                canonical_path: item.canonical_path,
                exists: item.exists,
                folder_backed: item.folder_backed,
                size_bytes: item.size_bytes,
                install_count: item.installs.len(),
                support_file_count: support_files.len(),
                is_favorite: meta.favorites.contains(&item.source_key),
                collections,
                is_heavy: item.size_bytes as usize >= HEAVY_ITEM_BYTES,
                installs: sort_installs(item.installs),
                support_files,
            }
        })
        .collect::<Vec<_>>();

    items.sort_by(|left, right| {
        left.display_name
            .to_ascii_lowercase()
            .cmp(&right.display_name.to_ascii_lowercase())
    });
    Ok(items)
}

fn sort_installs(mut installs: Vec<HarnessInstallView>) -> Vec<HarnessInstallView> {
    installs.sort_by(|left, right| left.path.cmp(&right.path));
    installs
}

fn status_for_record(record: &HarnessInstallRecordRow, install: &DiscoveredInstall) -> String {
    match record.backing_mode.as_str() {
        "symlink" => {
            let target = if install.folder_backed {
                install.root_path.canonicalize().ok()
            } else {
                install.path.canonicalize().ok()
            };
            let expected = if install.folder_backed {
                PathBuf::from(&record.source_root_path)
            } else {
                PathBuf::from(&record.source_path)
            };
            if target.as_ref() == Some(&expected) {
                "ok".to_string()
            } else {
                "drifted".to_string()
            }
        }
        "copy" => {
            match fingerprint_item(Path::new(&record.target_root_path), install.folder_backed) {
                Ok(current) => {
                    if record.last_synced_fingerprint.as_deref() == Some(current.as_str()) {
                        "ok".to_string()
                    } else {
                        "drifted".to_string()
                    }
                }
                Err(_) => "drifted".to_string(),
            }
        }
        _ => "ok".to_string(),
    }
}

fn resolve_item_as_source(item: &HarnessCatalogItemView) -> Result<ResolvedTarget, String> {
    Ok(ResolvedTarget {
        tool: item.primary_tool.clone(),
        scope: item.primary_scope.clone(),
        kind: item.kind.clone(),
        format: item.format.clone(),
        primary_path: PathBuf::from(&item.primary_path),
        root_path: PathBuf::from(&item.primary_root_path),
        folder_backed: item.folder_backed,
    })
}

fn validate_targets(
    kind: &str,
    inputs: &[HarnessTargetInput],
    context: &CatalogContext,
) -> Result<Vec<ResolvedTarget>, String> {
    if inputs.is_empty() {
        return Err("at least one target is required".to_string());
    }
    let mut seen = HashSet::<(String, String)>::new();
    let mut targets = Vec::new();
    for input in inputs {
        if !seen.insert((input.tool.clone(), input.scope.clone())) {
            continue;
        }
        targets.push(resolve_target(kind, &input.tool, &input.scope, context)?);
    }
    Ok(targets)
}

fn resolve_target(
    kind: &str,
    tool: &str,
    scope: &str,
    context: &CatalogContext,
) -> Result<ResolvedTarget, String> {
    let file_name = primary_file_name(kind)?;
    let format = "markdown".to_string();
    let root = match (kind, tool, scope) {
        ("skill", "claude", "user") => context.home.join(".claude/skills"),
        ("skill", "claude", "project") => context
            .project_root
            .as_ref()
            .ok_or_else(|| "project target requires an active project".to_string())?
            .join(".claude/skills"),
        ("skill", "codex", "user") => context.home.join(".codex/skills"),
        ("skill", "codex", "project") => context
            .project_root
            .as_ref()
            .ok_or_else(|| "project target requires an active project".to_string())?
            .join(".codex/skills"),
        ("skill", "global", "global") => context.home.join(".agents/skills"),
        ("agent", "claude", "user") => context.home.join(".claude/agents"),
        ("agent", "claude", "project") => context
            .project_root
            .as_ref()
            .ok_or_else(|| "project target requires an active project".to_string())?
            .join(".claude/agents"),
        ("command", "claude", "user") => context.home.join(".claude/commands"),
        ("command", "claude", "project") => context
            .project_root
            .as_ref()
            .ok_or_else(|| "project target requires an active project".to_string())?
            .join(".claude/commands"),
        _ => {
            return Err(format!("unsupported target for {kind}: {tool}/{scope}"));
        }
    };
    let slug = "__slug__";
    let root_path = root.join(slug);
    Ok(ResolvedTarget {
        tool: tool.to_string(),
        scope: scope.to_string(),
        kind: kind.to_string(),
        format,
        primary_path: root_path.join(file_name),
        root_path,
        folder_backed: true,
    })
}

fn resolve_library_target(
    kind: &str,
    slug: &str,
    context: &CatalogContext,
) -> Result<ResolvedTarget, String> {
    let file_name = primary_file_name(kind)?;
    let root_path = context.library_root.join(kind).join(slug);
    Ok(ResolvedTarget {
        tool: LIBRARY_TOOL.to_string(),
        scope: LIBRARY_SCOPE.to_string(),
        kind: kind.to_string(),
        format: "markdown".to_string(),
        primary_path: root_path.join(file_name),
        root_path,
        folder_backed: true,
    })
}

fn primary_file_name(kind: &str) -> Result<&'static str, String> {
    match kind {
        "skill" => Ok("SKILL.md"),
        "agent" => Ok("AGENTS.md"),
        "command" => Ok("COMMAND.md"),
        _ => Err(format!("unsupported creatable kind: {kind}")),
    }
}

fn default_template_for_kind(kind: &str, name: &str) -> Result<String, String> {
    let body = match kind {
        "skill" => format!(
            "---\nname: {}\ndescription: TODO\n---\n\n# {}\n\nDescribe when to use this skill, the workflow, and important constraints.\n",
            slugify(name),
            name
        ),
        "agent" => format!(
            "# {}\n\nDescribe the role, guardrails, expected workflow, and handoff expectations for this agent.\n",
            name
        ),
        "command" => format!(
            "# {}\n\nDescribe what this command does, when to invoke it, and any required arguments or context.\n",
            name
        ),
        _ => return Err(format!("unsupported creatable kind: {kind}")),
    };
    Ok(body)
}

fn slugify(input: &str) -> String {
    let mut output = String::new();
    let mut previous_hyphen = false;
    for ch in input.chars().flat_map(|ch| ch.to_lowercase()) {
        if ch.is_ascii_alphanumeric() {
            output.push(ch);
            previous_hyphen = false;
        } else if !previous_hyphen {
            output.push('-');
            previous_hyphen = true;
        }
    }
    let trimmed = output.trim_matches('-').to_string();
    let trimmed = if trimmed.is_empty() {
        "item".to_string()
    } else {
        trimmed
    };
    trimmed.chars().take(64).collect()
}

fn unique_slug_for_create(
    kind: &str,
    base_slug: String,
    targets: &[ResolvedTarget],
    context: &CatalogContext,
) -> Result<String, String> {
    if targets.len() == 1 {
        return Ok(base_slug);
    }
    unique_slug_for_library(kind, base_slug, context)
}

fn unique_slug_for_library(
    kind: &str,
    base_slug: String,
    context: &CatalogContext,
) -> Result<String, String> {
    let mut slug = if base_slug.is_empty() {
        "item".to_string()
    } else {
        base_slug
    };
    let mut index = 2;
    loop {
        let target = resolve_library_target(kind, &slug, context)?;
        if !target.root_path.exists() {
            return Ok(slug);
        }
        slug = format!("{}-{}", slugify(&slug), index);
        index += 1;
    }
}

fn with_slug(target: &ResolvedTarget, slug: &str) -> ResolvedTarget {
    let root_path = target
        .root_path
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join(slug);
    ResolvedTarget {
        tool: target.tool.clone(),
        scope: target.scope.clone(),
        kind: target.kind.clone(),
        format: target.format.clone(),
        primary_path: root_path.join(primary_file_name(&target.kind).unwrap_or("SKILL.md")),
        root_path,
        folder_backed: target.folder_backed,
    }
}

fn conflict_for_target(target: &ResolvedTarget, replace_existing: bool) -> Option<String> {
    if replace_existing {
        return None;
    }
    if target.root_path.exists() {
        Some("replace_required".to_string())
    } else {
        None
    }
}

fn prepare_target_for_write(target: &ResolvedTarget, replace_existing: bool) -> Result<(), String> {
    if target.root_path.exists() {
        if !replace_existing {
            return Err(format!(
                "target already exists: {}",
                target.root_path.display()
            ));
        }
        remove_path_safe(&target.root_path, &target.primary_path)?;
    }
    std::fs::create_dir_all(target.root_path.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| format!("failed to create target parent: {e}"))?;
    Ok(())
}

async fn write_primary_file(target: &ResolvedTarget, content: &str) -> Result<(), String> {
    tokio::fs::create_dir_all(&target.root_path)
        .await
        .map_err(|e| format!("failed to create target root: {e}"))?;
    tokio::fs::write(&target.primary_path, content)
        .await
        .map_err(|e| format!("failed to write {}: {e}", target.primary_path.display()))
}

#[allow(clippy::too_many_arguments)]
async fn install_target(
    global_db: &pnevma_db::GlobalDb,
    source_key: &str,
    source: &ResolvedTarget,
    target_template: &ResolvedTarget,
    replace_existing: bool,
    allow_copy_fallback: bool,
    source_fingerprint: &str,
    warnings: &mut Vec<String>,
    now: DateTime<Utc>,
    forget_only: bool,
) -> Result<(), String> {
    let slug = source
        .root_path
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("item")
        .to_string();
    let target = with_slug(target_template, &slug);
    prepare_target_for_write(&target, replace_existing)?;

    std::fs::create_dir_all(target.root_path.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| format!("failed to create install parent: {e}"))?;

    let symlink_result = if source.folder_backed {
        create_symlink(&source.root_path, &target.root_path)
    } else {
        create_symlink(&source.primary_path, &target.primary_path)
    };

    let (backing_mode, fingerprint) = match symlink_result {
        Ok(()) => ("symlink".to_string(), None),
        Err(err) if allow_copy_fallback => {
            warnings.push(format!(
                "Fell back to copy for {}: {}",
                target.root_path.display(),
                err
            ));
            copy_item_root(
                &source.root_path,
                &source.primary_path,
                &target.root_path,
                &target.primary_path,
                source.folder_backed,
            )?;
            ("copy".to_string(), Some(source_fingerprint.to_string()))
        }
        Err(err) => return Err(err),
    };

    let row = HarnessInstallRecordRow {
        id: Uuid::new_v4().to_string(),
        source_key: source_key.to_string(),
        source_path: source.primary_path.to_string_lossy().to_string(),
        source_root_path: source.root_path.to_string_lossy().to_string(),
        target_path: target.primary_path.to_string_lossy().to_string(),
        target_root_path: target.root_path.to_string_lossy().to_string(),
        tool: target.tool.clone(),
        scope: target.scope.clone(),
        backing_mode,
        removal_policy: if forget_only {
            "forget_only".to_string()
        } else {
            "delete_target".to_string()
        },
        last_synced_fingerprint: fingerprint,
        created_at: now,
        updated_at: now,
    };
    global_db
        .upsert_harness_install_record(&row)
        .await
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn create_symlink(source: &Path, target: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(source, target).map_err(|e| {
            format!(
                "failed to symlink {} -> {}: {e}",
                target.display(),
                source.display()
            )
        })
    }
    #[cfg(not(unix))]
    {
        let _ = source;
        let _ = target;
        Err("symlinks are unsupported on this platform".to_string())
    }
}

fn copy_item_root(
    source_root: &Path,
    source_primary: &Path,
    target_root: &Path,
    target_primary: &Path,
    folder_backed: bool,
) -> Result<(), String> {
    if folder_backed {
        copy_dir_recursive(source_root, target_root)?;
    } else {
        if let Some(parent) = target_primary.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("failed to create target parent: {e}"))?;
        }
        std::fs::copy(source_primary, target_primary)
            .map_err(|e| format!("failed to copy file: {e}"))?;
    }
    Ok(())
}

fn copy_dir_recursive(source: &Path, target: &Path) -> Result<(), String> {
    std::fs::create_dir_all(target)
        .map_err(|e| format!("failed to create {}: {e}", target.display()))?;
    let entries = std::fs::read_dir(source)
        .map_err(|e| format!("failed to read {}: {e}", source.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("failed to read dir entry: {e}"))?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|e| format!("failed to stat {}: {e}", path.display()))?;
        if metadata.file_type().is_symlink() {
            return Err(format!(
                "cannot copy symlinked support file: {}",
                path.display()
            ));
        }
        let destination = target.join(entry.file_name());
        if metadata.is_dir() {
            copy_dir_recursive(&path, &destination)?;
        } else if metadata.is_file() {
            std::fs::copy(&path, &destination)
                .map_err(|e| format!("failed to copy {}: {e}", path.display()))?;
        }
    }
    Ok(())
}

fn remove_path_safe(root_path: &Path, primary_path: &Path) -> Result<(), String> {
    if root_path.exists() && (root_path.is_dir() || symlink_metadata_is_symlink(root_path)) {
        std::fs::remove_dir_all(root_path)
            .map_err(|e| format!("failed to remove {}: {e}", root_path.display()))?;
        return Ok(());
    }
    if primary_path.exists() {
        std::fs::remove_file(primary_path)
            .map_err(|e| format!("failed to remove {}: {e}", primary_path.display()))?;
    }
    Ok(())
}

fn fingerprint_item(root_path: &Path, folder_backed: bool) -> Result<String, String> {
    if !root_path.exists() {
        return Err(format!("missing item root: {}", root_path.display()));
    }
    if !folder_backed {
        let bytes = std::fs::read(root_path)
            .map_err(|e| format!("failed to read {}: {e}", root_path.display()))?;
        return Ok(sha256_hex(&bytes));
    }
    let mut manifest = Vec::<u8>::new();
    let canonical_root = root_path
        .canonicalize()
        .map_err(|e| format!("failed to resolve {}: {e}", root_path.display()))?;
    let mut files = Vec::<PathBuf>::new();
    collect_fingerprint_files(&canonical_root, &canonical_root, &mut files)?;
    files.sort();
    for file in files {
        let rel = file
            .strip_prefix(&canonical_root)
            .unwrap_or(&file)
            .to_string_lossy()
            .to_string();
        manifest.extend_from_slice(rel.as_bytes());
        manifest.extend_from_slice(&[0]);
        let bytes =
            std::fs::read(&file).map_err(|e| format!("failed to read {}: {e}", file.display()))?;
        manifest.extend_from_slice(&bytes);
        manifest.extend_from_slice(&[0]);
    }
    Ok(sha256_hex(&manifest))
}

fn collect_fingerprint_files(
    root: &Path,
    current: &Path,
    files: &mut Vec<PathBuf>,
) -> Result<(), String> {
    for entry in std::fs::read_dir(current)
        .map_err(|e| format!("failed to read {}: {e}", current.display()))?
    {
        let entry = entry.map_err(|e| format!("failed to read dir entry: {e}"))?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|e| format!("failed to stat {}: {e}", path.display()))?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            collect_fingerprint_files(root, &path, files)?;
        } else if metadata.is_file() {
            let canonical = path
                .canonicalize()
                .map_err(|e| format!("failed to resolve {}: {e}", path.display()))?;
            if canonical.starts_with(root) {
                files.push(canonical);
            }
        }
    }
    Ok(())
}

fn discover_custom_root(
    items: &mut Vec<DiscoveredInstall>,
    root: &Path,
    library_root: &Path,
) -> Result<(), String> {
    let normalized_root = normalize_discoverable_root(root)?;
    discover_items_in_root(
        items,
        normalized_root.clone(),
        &[normalized_root.clone(), library_root.to_path_buf()],
        "custom",
        "library",
        "skill",
        &["SKILL.md", "AGENTS.md"],
        &["md", "mdc", "toml"],
    );

    let Ok(entries) = std::fs::read_dir(&normalized_root) else {
        return Ok(());
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        discover_items_in_root(
            items,
            path.join(".claude/skills"),
            &[path.clone(), library_root.to_path_buf()],
            "claude",
            "project",
            "skill",
            &["SKILL.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            items,
            path.join(".claude/agents"),
            &[path.clone(), library_root.to_path_buf()],
            "claude",
            "project",
            "agent",
            &["AGENTS.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            items,
            path.join(".claude/commands"),
            &[path.clone(), library_root.to_path_buf()],
            "claude",
            "project",
            "command",
            &["COMMAND.md", "SKILL.md"],
            &["md"],
        );
        discover_items_in_root(
            items,
            path.join(".codex/skills"),
            &[path.clone(), library_root.to_path_buf()],
            "codex",
            "project",
            "skill",
            &["SKILL.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            items,
            path.join(".codex/rules"),
            &[path.clone(), library_root.to_path_buf()],
            "codex",
            "project",
            "rule",
            &["RULE.md"],
            &["md", "mdc", "toml"],
        );
        discover_items_in_root(
            items,
            path.join(".agents/skills"),
            &[path.clone(), library_root.to_path_buf()],
            "global",
            "project",
            "skill",
            &["SKILL.md"],
            &["md", "mdc", "toml"],
        );
        push_fixed_file(
            items,
            path.join("AGENTS.md"),
            &[path.clone(), library_root.to_path_buf()],
            "codex",
            "project",
            "agent",
            Some("Repo AGENTS.md"),
        );
    }
    Ok(())
}

fn push_fixed_file(
    items: &mut Vec<DiscoveredInstall>,
    path: PathBuf,
    allowed_roots: &[PathBuf],
    tool: &str,
    scope: &str,
    kind: &str,
    display_name: Option<&str>,
) {
    if let Some(item) =
        build_item_from_file(path, allowed_roots, tool, scope, kind, display_name, false)
    {
        items.push(item);
    }
}

#[allow(clippy::too_many_arguments)]
fn discover_items_in_root(
    items: &mut Vec<DiscoveredInstall>,
    root: PathBuf,
    allowed_roots: &[PathBuf],
    tool: &str,
    scope: &str,
    kind: &str,
    primary_names: &[&str],
    loose_extensions: &[&str],
) {
    if !root.is_dir() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(&root) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if is_ignored_name(&name) {
            continue;
        }

        if path.is_dir() {
            if let Some(primary) =
                find_directory_primary_file(&path, primary_names, loose_extensions)
            {
                if let Some(item) =
                    build_item_from_file(primary, allowed_roots, tool, scope, kind, None, true)
                {
                    items.push(item);
                }
            }
            continue;
        }

        let ext = path
            .extension()
            .and_then(OsStr::to_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !loose_extensions.iter().any(|candidate| *candidate == ext) {
            continue;
        }
        if let Some(item) =
            build_item_from_file(path, allowed_roots, tool, scope, kind, None, false)
        {
            items.push(item);
        }
    }
}

fn find_directory_primary_file(
    dir: &Path,
    primary_names: &[&str],
    loose_extensions: &[&str],
) -> Option<PathBuf> {
    for primary_name in primary_names {
        let candidate = dir.join(primary_name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }

    let entries = std::fs::read_dir(dir).ok()?;
    let mut candidates = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if is_ignored_name(&name) {
            continue;
        }
        let ext = path
            .extension()
            .and_then(OsStr::to_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        if loose_extensions.iter().any(|candidate| *candidate == ext) {
            candidates.push(path);
        }
    }

    let dir_name = dir
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    if let Some(path) = candidates.iter().find(|path| {
        path.file_stem()
            .and_then(OsStr::to_str)
            .unwrap_or_default()
            .to_ascii_lowercase()
            == dir_name
    }) {
        return Some(path.clone());
    }

    if candidates.len() == 1 {
        return candidates.into_iter().next();
    }

    None
}

fn build_item_from_file(
    path: PathBuf,
    allowed_roots: &[PathBuf],
    tool: &str,
    scope: &str,
    kind: &str,
    display_name_override: Option<&str>,
    folder_backed: bool,
) -> Option<DiscoveredInstall> {
    if !path.is_file() {
        return None;
    }
    let canonical_path = path.canonicalize().ok()?;
    if !path_within_any(&canonical_path, allowed_roots) {
        return None;
    }
    let root_path = if folder_backed {
        path.parent()?.to_path_buf()
    } else {
        path.clone()
    };
    let canonical_root_path = if folder_backed {
        root_path.canonicalize().ok()?
    } else {
        canonical_path.clone()
    };
    if !path_within_any(&canonical_root_path, allowed_roots) {
        return None;
    }

    let format = format_for_path(&path).to_string();
    let metadata = std::fs::metadata(&canonical_path).ok()?;
    let (display_name, summary) = metadata_for_file(&canonical_path, display_name_override)
        .unwrap_or_else(|| {
            (
                fallback_name_for_path(&canonical_path, display_name_override),
                None::<String>,
            )
        });
    let support_files = if folder_backed {
        collect_support_files(&root_path, &path, allowed_roots)
    } else {
        Vec::new()
    };

    Some(DiscoveredInstall {
        display_name,
        summary,
        kind: kind.to_string(),
        tool: tool.to_string(),
        scope: scope.to_string(),
        format,
        path,
        root_path,
        canonical_path,
        canonical_root_path,
        folder_backed,
        size_bytes: metadata.len(),
        support_files,
    })
}

fn path_within_any(path: &Path, allowed_roots: &[PathBuf]) -> bool {
    allowed_roots
        .iter()
        .filter_map(|root| normalize_optional_root(root.as_path()))
        .any(|root| path.starts_with(&root))
}

fn normalize_optional_root(path: &Path) -> Option<PathBuf> {
    path.canonicalize()
        .ok()
        .or_else(|| Some(path.to_path_buf()))
}

fn metadata_for_file(
    path: &Path,
    display_name_override: Option<&str>,
) -> Option<(String, Option<String>)> {
    let raw = std::fs::read_to_string(path).ok()?;
    if !matches!(
        format_for_path(path),
        "markdown" | "yaml" | "toml" | "json" | "text"
    ) {
        return None;
    }
    let (frontmatter, body) = parse_frontmatter_and_body(&raw);
    let display_name = display_name_override
        .map(ToString::to_string)
        .or_else(|| frontmatter.get("name").cloned())
        .or_else(|| first_markdown_heading(&body))
        .unwrap_or_else(|| fallback_name_for_path(path, None));
    let summary = frontmatter
        .get("description")
        .cloned()
        .or_else(|| first_non_heading_line(&body));
    Some((display_name, summary))
}

fn parse_frontmatter_and_body(raw: &str) -> (HashMap<String, String>, String) {
    let normalized = raw.replace("\r\n", "\n");
    let trimmed = normalized.trim_start();
    if !trimmed.starts_with("---\n") {
        return (HashMap::new(), normalized);
    }
    let remainder = &trimmed[4..];
    let Some(end_idx) = remainder.find("\n---\n") else {
        return (HashMap::new(), normalized);
    };
    let yaml = &remainder[..end_idx];
    let body = remainder[end_idx + 5..].to_string();
    let parsed = yaml
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                return None;
            }
            let (key, value) = trimmed.split_once(':')?;
            Some((
                key.trim().to_string(),
                value
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .to_string(),
            ))
        })
        .collect::<HashMap<_, _>>();
    (parsed, body)
}

fn first_markdown_heading(body: &str) -> Option<String> {
    body.lines()
        .map(str::trim)
        .find(|line| line.starts_with("# "))
        .map(|line| line.trim_start_matches("# ").trim().to_string())
}

fn first_non_heading_line(body: &str) -> Option<String> {
    body.lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| line.to_string())
}

fn fallback_name_for_path(path: &Path, display_name_override: Option<&str>) -> String {
    if let Some(display_name) = display_name_override {
        return display_name.to_string();
    }
    let file_name = path.file_name().and_then(OsStr::to_str).unwrap_or_default();
    if matches!(
        file_name,
        "SKILL.md" | "AGENTS.md" | "COMMAND.md" | "RULE.md" | "MEMORY.md"
    ) {
        return path
            .parent()
            .and_then(Path::file_name)
            .and_then(OsStr::to_str)
            .unwrap_or(file_name)
            .to_string();
    }
    path.file_stem()
        .and_then(OsStr::to_str)
        .unwrap_or(file_name)
        .to_string()
}

fn collect_support_files(
    root_dir: &Path,
    primary_path: &Path,
    allowed_roots: &[PathBuf],
) -> Vec<HarnessSupportFileView> {
    let mut files = Vec::new();
    let mut visited = HashSet::<PathBuf>::new();
    collect_support_files_recursive(
        root_dir,
        root_dir,
        primary_path,
        allowed_roots,
        &mut visited,
        &mut files,
    );
    files.sort_by(|left, right| left.rel_path.cmp(&right.rel_path));
    files.truncate(SUPPORT_FILE_LIMIT);
    files
}

fn collect_support_files_recursive(
    current_dir: &Path,
    root_dir: &Path,
    primary_path: &Path,
    allowed_roots: &[PathBuf],
    visited: &mut HashSet<PathBuf>,
    files: &mut Vec<HarnessSupportFileView>,
) {
    let canonical_dir = match current_dir.canonicalize() {
        Ok(path) => path,
        Err(_) => return,
    };
    if !visited.insert(canonical_dir.clone()) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(current_dir) else {
        return;
    };
    for entry in entries.flatten() {
        if files.len() >= SUPPORT_FILE_LIMIT {
            return;
        }
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || matches!(name.as_str(), "__pycache__" | "node_modules") {
            continue;
        }
        if path == primary_path {
            continue;
        }
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            collect_support_files_recursive(
                &path,
                root_dir,
                primary_path,
                allowed_roots,
                visited,
                files,
            );
            continue;
        }
        if !metadata.is_file() {
            continue;
        }
        let Ok(canonical) = path.canonicalize() else {
            continue;
        };
        if !path_within_any(&canonical, allowed_roots) {
            continue;
        }
        let rel_path = path
            .strip_prefix(root_dir)
            .unwrap_or(&path)
            .to_string_lossy()
            .to_string();
        files.push(HarnessSupportFileView {
            rel_path,
            path: path.to_string_lossy().to_string(),
            format: format_for_path(&path).to_string(),
            size_bytes: metadata.len(),
        });
    }
}

fn is_ignored_name(name: &str) -> bool {
    matches!(
        name.to_ascii_lowercase().as_str(),
        ".ds_store"
            | "readme"
            | "readme.md"
            | "license"
            | "license.md"
            | "changelog.md"
            | "global_rules.md"
            | "claude.md"
    )
}

fn format_for_path(path: &Path) -> &'static str {
    match path.extension().and_then(OsStr::to_str) {
        Some("json") => "json",
        Some("toml") => "toml",
        Some("yaml") | Some("yml") => "yaml",
        Some("md") | Some("mdc") => "markdown",
        _ => "text",
    }
}

fn validate_content(content: &str, format: &str) -> Result<(), String> {
    match format {
        "json" => {
            serde_json::from_str::<Value>(content).map_err(|e| format!("invalid JSON: {e}"))?;
        }
        "toml" => {
            content
                .parse::<toml::Table>()
                .map_err(|e| format!("invalid TOML: {e}"))?;
        }
        _ => {}
    }
    Ok(())
}

fn create_backup(path: &Path, source_key: &str) -> Result<(), String> {
    if !path.is_file() {
        return Ok(());
    }
    let home = std::env::var("HOME")
        .map(PathBuf::from)
        .map_err(|_| "HOME environment variable not set".to_string())?;
    let backup_dir = home.join(".config/pnevma/harness-backups");
    std::fs::create_dir_all(&backup_dir)
        .map_err(|e| format!("failed to create backup dir: {e}"))?;
    let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S_%f");
    let backup_name = format!(
        "{}.{}.{}.bak",
        path.file_name()
            .and_then(OsStr::to_str)
            .unwrap_or("harness"),
        &source_key[..source_key.len().min(12)],
        timestamp
    );
    let backup_path = backup_dir.join(backup_name);
    std::fs::copy(path, &backup_path).map_err(|e| format!("failed to create backup: {e}"))?;
    debug!(backup = %backup_path.display(), "created harness catalog backup");
    Ok(())
}

fn expand_home_path(input: &str) -> Result<PathBuf, String> {
    if input.is_empty() {
        return Err("path is required".to_string());
    }
    if let Some(rest) = input.strip_prefix("~/") {
        let home = std::env::var("HOME")
            .map(PathBuf::from)
            .map_err(|_| "HOME environment variable not set".to_string())?;
        return Ok(home.join(rest));
    }
    Ok(PathBuf::from(input))
}

fn normalize_discoverable_root(path: &Path) -> Result<PathBuf, String> {
    let canonical = path
        .canonicalize()
        .map_err(|e| format!("failed to resolve {}: {e}", path.display()))?;
    if !canonical.is_dir() {
        return Err(format!("not a directory: {}", canonical.display()));
    }
    Ok(canonical)
}

fn symlink_metadata_is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn parse_frontmatter_prefers_name_and_description() {
        let content = r#"---
name: test-skill
description: says hello
---

# Ignored title

Body line
"#;
        let (frontmatter, body) = parse_frontmatter_and_body(content);
        assert_eq!(
            frontmatter.get("name").map(String::as_str),
            Some("test-skill")
        );
        assert_eq!(
            frontmatter.get("description").map(String::as_str),
            Some("says hello")
        );
        assert!(body.contains("Ignored title"));
    }

    #[test]
    fn support_files_collects_nested_files_except_primary() {
        let temp = TempDir::new().expect("temp dir");
        let skill_dir = temp.path().join("demo-skill");
        fs::create_dir_all(skill_dir.join("scripts")).expect("create scripts");
        fs::write(skill_dir.join("SKILL.md"), "# Demo").expect("write primary");
        fs::write(skill_dir.join("README.md"), "doc").expect("write readme");
        fs::write(skill_dir.join("scripts/tool.py"), "print('hi')").expect("write script");

        let files = collect_support_files(
            &skill_dir,
            &skill_dir.join("SKILL.md"),
            std::slice::from_ref(&skill_dir),
        );
        let rel_paths = files
            .into_iter()
            .map(|file| file.rel_path)
            .collect::<Vec<_>>();
        assert_eq!(
            rel_paths,
            vec!["README.md".to_string(), "scripts/tool.py".to_string()]
        );
    }

    #[test]
    fn directory_primary_prefers_matching_name_then_single_candidate() {
        let temp = TempDir::new().expect("temp dir");
        let dir = temp.path().join("matcher");
        fs::create_dir_all(&dir).expect("create dir");
        fs::write(dir.join("README.md"), "skip").expect("write readme");
        fs::write(dir.join("matcher.md"), "# Match").expect("write match");
        fs::write(dir.join("other.md"), "# Other").expect("write other");

        let primary =
            find_directory_primary_file(&dir, &["SKILL.md"], &["md"]).expect("primary file");
        assert!(primary.ends_with("matcher.md"));
    }

    #[test]
    fn fallback_name_uses_parent_for_skill_md() {
        let name = fallback_name_for_path(Path::new("/tmp/demo/SKILL.md"), None);
        assert_eq!(name, "demo");
    }

    #[test]
    fn slugify_normalizes_name() {
        assert_eq!(slugify("Hello, World!"), "hello-world");
        assert_eq!(slugify("***"), "item");
    }

    #[test]
    fn support_files_skip_symlink_cycles() {
        use std::os::unix::fs::symlink;
        let temp = TempDir::new().expect("temp dir");
        let skill_dir = temp.path().join("demo-skill");
        fs::create_dir_all(skill_dir.join("scripts")).expect("create scripts");
        fs::write(skill_dir.join("SKILL.md"), "# Demo").expect("write primary");
        symlink(&skill_dir, skill_dir.join("scripts/loop")).expect("symlink loop");
        let files = collect_support_files(
            &skill_dir,
            &skill_dir.join("SKILL.md"),
            std::slice::from_ref(&skill_dir),
        );
        assert!(files.is_empty());
    }
}
