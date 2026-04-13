# Wrist Audio Timeline Schema

This repository defines the canonical data model for the current wrist-audio pipeline.

The operational scope is intentionally audio-only today. The model is intentionally structured so future modalities can be added without redesigning the core rules for time, references, lineage, quality, or validation.

## Repository contents

- `schema.py`: the canonical Python schema for exchange, validation, and bundle integrity checks
- `SCHEMA.md`: the normative schema specification
- `schema.sql`: the normalized PostgreSQL persistence schema

## Design goals

1. Relative time is authoritative.
2. Wall-clock is optional advisory metadata.
3. Root records and timeline objects are distinct concepts.
4. Typed references are the default way to connect records.
5. Derived objects and fused objects have different roles and should stay separate.
6. The canonical schema and the persistence schema should share semantics even when their physical shapes differ.

## Schema layers

### Canonical schema

`schema.py` is the source of truth for the in-memory and over-the-wire shape of a session bundle.

It defines:

- root records
- timeline object families and current audio object kinds
- typed references
- confidence and quality payloads
- bundle-level validation rules

### Persistence schema

`schema.sql` is the normalized PostgreSQL projection of the same model.

It keeps the same semantics while flattening nested structures into relational tables:

- lookup catalogs store evolving vocabularies
- core tables store root records and timeline object headers
- child tables store refs, tags, notes, subscores, provenance, and properties
- audio-specific subtype and payload tables keep the current runtime scope intentionally narrow

### Normative specification

`SCHEMA.md` defines the contract that both schema layers are expected to honor.

## Core concepts

### Root records

The root records are:

- `CaptureSession`
- `SensorStream`
- `Artifact`

These records establish the session boundary and the durable inputs or outputs attached to it.

`Artifact` uses typed `ArtifactStreamRef` links instead of a single raw `stream_id`. That keeps the current audio flow simple while leaving room for multi-stream artifacts later.

### Timeline objects

Every timeline object belongs to exactly one family:

- `observation`
- `evidence`
- `derived`
- `fusion`

The current audio scope includes:

- `AudioDspBinObservation`
- `AudioContextWindowEvidence`
- `AudioAsrWordEvidence`
- `AudioAsrSegmentEvidence`
- `AudioAsrCorrectionEvidence`
- `AudioDiarizationSegmentEvidence`
- `AudioSpeakerIdentificationEvidence`
- `AudioEmotionWindowEvidence`
- `AudioEmotionSegmentEvidence`
- `AudioSoundEventSegmentEvidence`
- `ContextSegment`
- `ContextChangeMarker`
- `QualityBin`
- `FusedInterval`

### Time model

The timeline model is centered on relative offsets from session start.

- `RelativeInstant` and `RelativeSpan` are the canonical temporal types
- object-level `timebase` metadata is retained so alignment assumptions stay explicit
- wall-clock estimates remain optional and advisory
- canonical grids are declared separately and referenced when an object is produced on a known grid

The currently seeded grids are:

- `audio_base_500ms`
- `audio_context_30s_15s`

### References and lineage

All cross-record links should use typed references:

- `StreamRef`
- `ArtifactRef`
- `ObjectRef`

Primary lineage uses:

- `derived_from`
- `fused_from`

Role-specific links such as `word_refs`, `supporting_objects`, `applies_to`, and `context_segment` add structure but do not replace primary lineage.

### Confidence and quality

`ConfidenceBundle` represents pipeline-level reliability, not raw model-native confidence.

`QualityBin` is the canonical derived object for dense quality and usability scoring. Reserved keys are defined once and shared across the repo so validators, docs, and storage all agree on the same vocabulary.

## Audio-only scope, modality-extensible core

The current runtime scope is deliberately narrow:

- one audio modality
- one microphone stream kind
- audio-specific object kinds
- audio-specific durable payload tables

The extension path is deliberate rather than accidental. New modalities should be added by extending the existing model, not by weakening it:

- add new modality catalog rows
- add new stream kinds, artifact formats, and object kinds as needed
- add sibling subtype or payload tables for new modality-specific data
- keep the relative time model, typed refs, lineage rules, and bundle validation rules unchanged

## Persistence mapping notes

Some concepts stay semantically identical while being stored differently:

- nested notes and tags are decomposed into child tables
- `Artifact.stream_refs` persist through `artifact_stream_ref`
- `CaptureSession.wall_clock_start` persists as the `session_wall_clock_candidate` row marked `is_primary = true`
- object `timebase` fields persist directly on `timeline_object`
- convenience object links persist through `object_ref`

This is intentional. The persistence schema is a normalized representation of the canonical schema, not a separate contract.

## Current non-goals

These are intentionally out of operational scope for this phase:

- video
- GPS
- IMU
- BLE
- phone state
- calendar feeds
- cross-modality fusion beyond audio

Those can be added later through explicit schema extension work rather than implicit ad hoc fields.
