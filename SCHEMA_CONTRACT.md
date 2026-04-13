## SCHEMA CONTRACT

This document defines the normative contract for schema version `v1.0.0-alpha.1`. Relative timeline semantics are the authoritative basis for all core pipeline behavior. Wall-clock data is optional advisory metadata only.

### 1. Timing

All core timing logic MUST use `RelativeInstant` and `RelativeSpan`. Relative offsets MUST be treated as canonical for alignment, projection, derivation, fusion, and validation. Wall-clock fields MUST NOT be required for pipeline operation. If wall-clock estimates are present, they MUST be timezone-aware UTC values and MUST be treated as informational rather than authoritative.

### 2. Record model and timeline families

The schema distinguishes between root records and timeline object families.

Root records are `capture_session`, `sensor_stream`, and `artifact`.

Every timeline object MUST belong to exactly one timeline family: `observation`, `evidence`, `derived`, or `fusion`. `Observation` objects MUST represent baseline timeline observations. `Evidence` objects MUST represent direct model outputs. `Derived` objects MUST represent deterministic products of earlier objects. `Fusion` objects MUST represent fused interpretive intervals intended for downstream use.

### 3. Grids

The `grid` field MAY be populated only for objects produced on a declared regular or sliding grid. Objects not produced from a declared grid SHOULD leave `grid` unset. The canonical grid IDs for the current system are `audio_base_500ms` and `audio_context_30s_15s`.

### 4. References

Implementations MUST use `StreamRef`, `ArtifactRef`, and `ObjectRef` for typed references. Raw untyped IDs SHOULD NOT be used where a typed ref is available. If `expected_role`, `expected_kind`, or `expected_family` is supplied, validators MUST enforce it. Unknown referenced objects, streams, or artifacts MUST be rejected.

### 5. Lineage

`derived_from` and `fused_from` MUST be treated as the primary semantic lineage links. Payload-level references such as `supporting_objects`, `word_refs`, `applies_to`, `left_object`, `right_object`, and `context_segment` MAY provide role-specific context, but they MUST NOT replace `derived_from` or `fused_from` as canonical lineage.

### 6. Native outputs and metadata

`native_outputs` MUST contain small implementation-specific model-native values when retained inline. `service_metadata` SHOULD contain operational metadata such as thresholds, parser notes, or prompt versions. Full raw outputs SHOULD be stored as artifacts and linked through `raw_output_artifact_refs`. Implementations MUST NOT overload `attributes` with values that belong in `native_outputs` or `service_metadata`.

### 7. Confidence

`ConfidenceBundle` MUST represent pipeline-level reliability or usability judgment. Native model confidence, when available, SHOULD be stored in `native_outputs`, not substituted directly for fused confidence. `subscores` MUST be the canonical location for task-specific reliability values. Absence of native model confidence MUST NOT prevent construction of a valid `ConfidenceBundle`.

### 8. Quality vocabulary

`QualityBinPayload.metrics` and `QualityBinPayload.usability` MUST use the reserved vocabularies unless extended with `x_` or `custom:` prefixes. Reserved metric keys are `rms_dbfs`, `estimated_snr_db`, `speech_ratio`, `overlap_risk`, `boundary_risk`, and `asr_gap_density`. Reserved usability keys are `asr`, `speaker`, `emotion`, `sound_event`, `acoustic_scene`, and `overall`. Validators MUST reject unsupported unprefixed keys.

### 9. Artifacts

`Artifact.format` MUST be used for artifact serialization or encoding labels such as `wav`, `flac`, `json`, or `parquet`. Implementations MUST NOT overload this field with unrelated operational metadata.

### 10. Bundle integrity

A `SessionBundle` MUST reject duplicate stream IDs, artifact IDs, or object IDs. All streams, artifacts, and objects in a bundle MUST belong to the same session. Validators MUST reject unknown references and violated expected role, kind, or family assertions. Temporal containment checks MAY be performed when sufficient bounds are known, but they are OPTIONAL and MUST NOT be assumed universally available.

### 11. Scope

For the current phase, implementations MUST treat the schema as audio-focused in operational scope. Future modalities MAY be added later without changing the core rules above. Until such expansion occurs, this schema MUST be treated as the single source of truth for timing, lineage, reference integrity, confidence semantics, and cross-service interoperability in the wrist-worn audio pipeline.
