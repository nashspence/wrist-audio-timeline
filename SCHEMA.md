# Schema Specification

This document is normative for schema version `v1.0.0-alpha.1`.

Unless noted otherwise, the requirements below apply to both the canonical exchange schema in `schema.py` and the PostgreSQL persistence schema in `schema.sql`.

## 1. Scope and authority

The current runtime scope is audio-only. Implementations MUST treat this repository as the single source of truth for:

- relative timeline semantics
- typed references
- lineage rules
- confidence semantics
- quality vocabulary
- bundle integrity

The core model is intentionally modality-extensible. Future modalities MAY be added later, but they MUST extend the existing model rather than redefine its timing, lineage, or reference rules.

## 2. Schema layers

`schema.py` defines the canonical session-bundle shape used for validation and interchange.

`schema.sql` defines a normalized persistence projection of the same semantics.

When the persistence schema decomposes nested collections into child tables, implementations MUST preserve the same meaning as the canonical schema rather than inventing storage-specific semantics.

## 3. Root records

The root records are:

- `capture_session`
- `sensor_stream`
- `artifact`

Timeline-object families apply only to timeline objects. Root records MUST NOT be treated as belonging to timeline families.

### Capture session

`CaptureSession` defines the session boundary and optional advisory wall-clock metadata.

- Relative offsets remain authoritative.
- Wall-clock estimates MUST be treated as informational only.
- A primary wall-clock estimate MAY be designated.

In the persistence schema, `CaptureSession.wall_clock_start` maps to the `session_wall_clock_candidate` row where `is_primary = true`.

### Sensor stream

`SensorStream` defines a source stream within a session.

For the current phase:

- `modality` MUST be `audio`
- `stream_kind` MUST be `microphone`

The model MUST still remain extensible enough to add new modalities and stream kinds later.

### Artifact

`Artifact` defines stored media, transcripts, embeddings, model-native outputs, feature shards, and other durable outputs.

- Artifacts MUST use `artifact_role`.
- Artifacts SHOULD use `artifact_format` when the serialization format is known.
- Artifacts MAY reference zero, one, or many streams through typed `ArtifactStreamRef` links.
- At most one artifact-stream link MAY be marked primary.

## 4. Timeline objects

Every timeline object MUST belong to exactly one family:

- `observation`
- `evidence`
- `derived`
- `fusion`

The family definitions are:

- `observation`: baseline timeline measurements or low-level observations
- `evidence`: direct upstream model outputs
- `derived`: deterministic products built from earlier objects
- `fusion`: fused interpretive intervals intended for downstream use

Implementations MUST preserve this distinction. Derived objects MUST NOT be used as a substitute for fusion outputs, and fusion outputs MUST NOT be treated as raw evidence.

## 5. Time model

All core timing logic MUST use relative time.

- `RelativeInstant` and `RelativeSpan` are the canonical temporal forms.
- Relative offsets MUST be interpreted as offsets from session start.
- Wall-clock values MUST NOT be required for alignment, projection, derivation, fusion, or validation.

Every timeline object MUST carry an explicit `timebase`.

- `clock_source` identifies how the relative time should be interpreted.
- `reference_stream_id`, when present, MUST point to a known stream in the same session.
- `alignment_uncertainty_ms`, when present, MUST be non-negative.

The persistence schema MUST retain the timebase fields on `timeline_object`.

## 6. Grids

The `grid` field MAY be populated only for objects produced on a declared grid.

Objects not produced on a declared grid SHOULD leave `grid` unset.

The currently seeded canonical grid IDs are:

- `audio_base_500ms`
- `audio_context_30s_15s`

Future grids MAY be added later without changing the rest of the time model.

## 7. References and lineage

Implementations MUST use typed references whenever a typed ref is available:

- `StreamRef`
- `ArtifactRef`
- `ObjectRef`

Validators MUST reject unknown referenced streams, artifacts, or objects.

If `expected_role`, `expected_kind`, or `expected_family` is supplied, validators MUST enforce it.

Primary lineage uses:

- `derived_from`
- `fused_from`

Role-specific links such as `word_refs`, `applies_to`, `supporting_objects`, `left_object`, `right_object`, and `context_segment` MAY add structure, but they MUST NOT replace primary lineage.

## 8. Payload and metadata separation

The schema distinguishes between several different kinds of payload detail:

- `attributes`: flexible record- or object-level properties
- `native_outputs`: small model-native values retained inline
- `service_metadata`: operational metadata such as thresholds, parser notes, or prompt versions
- `raw_output_artifact_refs`: links to full raw outputs stored as artifacts

Implementations MUST keep these concerns separate.

- Values that are model-native SHOULD live in `native_outputs`.
- Values that describe execution details SHOULD live in `service_metadata`.
- Large raw outputs SHOULD be stored as artifacts.
- `attributes` MUST NOT be used as a catch-all replacement for the more specific fields above.

## 9. Confidence and quality

`ConfidenceBundle` MUST represent pipeline-level reliability or usability judgment.

- Native model confidence, when available, SHOULD remain in `native_outputs`.
- Native model confidence MUST NOT be copied into `ConfidenceBundle` without interpretation.
- `subscores` MUST be the canonical location for task-specific reliability values.

`QualityBinPayload.metrics` and `QualityBinPayload.usability` MUST use the reserved vocabularies unless extended with `x_` or `custom:` prefixes.

Reserved metric keys:

- `rms_dbfs`
- `estimated_snr_db`
- `speech_ratio`
- `overlap_risk`
- `boundary_risk`
- `asr_gap_density`

Reserved usability keys:

- `asr`
- `speaker`
- `emotion`
- `sound_event`
- `acoustic_scene`
- `overall`

Absent quality metrics SHOULD be omitted rather than emitted as null-valued entries.

## 10. Context and fusion semantics

`ContextSegment` is the canonical derived context object.

Its payload SHOULD stay structurally aligned with broad audio-context evidence where practical:

- short and detailed summaries
- acoustic-scene and sound-event tags
- speech-presence assessment
- groundedness
- uncertainty notes
- summarized audio profile

`FusedInterval` is the canonical fusion object for durable downstream interpretation.

Convenience references stored inside nested payloads, such as transcript word refs or a linked context segment, MUST still obey the same typed-reference and lineage rules as any other object link.

## 11. Persistence mapping

The persistence schema is normative for storage shape, but it is not a second semantic contract.

The following mappings are required:

- nested properties map to property tables
- nested refs map to dedicated ref tables
- notes and tags map to child tables
- `Artifact.stream_refs` maps to `artifact_stream_ref`
- object `timebase` maps to `timeline_object` timebase columns
- `CaptureSession.wall_clock_start` maps to the primary `session_wall_clock_candidate`

When a canonical structure is normalized into multiple tables, implementations MUST preserve the same semantics and constraints.

## 12. Bundle integrity

A `SessionBundle` MUST reject:

- duplicate stream IDs
- duplicate artifact IDs
- duplicate object IDs
- cross-session contamination
- unknown stream, artifact, or object references
- violated expected role, kind, or family assertions
- invalid timebase reference streams

Temporal containment checks MAY be performed when enough duration information is present, but they are OPTIONAL and MUST NOT be assumed universally available.

## 13. Extension rules

Future modalities MAY be added, but only through explicit schema extension.

That extension SHOULD happen by:

- adding new catalog rows
- adding new subtype or payload tables
- adding new modality-specific object kinds
- adding new grids or vocabularies when needed

It MUST NOT happen by weakening the current audio contract into an untyped or modality-ambiguous shape.
