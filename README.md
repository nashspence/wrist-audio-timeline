# Wrist Audio Timeline Schema

## Overview

This repository defines the canonical internal schema for a wrist-worn audio understanding pipeline.

The schema is designed for a system that ingests a single wearable microphone stream, runs multiple specialist audio models, projects all outputs onto a shared relative timeline, derives higher-level context objects, and then produces fused interval-level interpretations.

The core design goal is to make all services interoperable through one stable contract.

The current implementation version is `v1.0.0-alpha.1`.

## Core principles

1. **Relative timeline is authoritative**  
   All core timing is expressed as offsets from session start. Relative offsets are the canonical basis for alignment, projection, derivation, fusion, and validation.

2. **Wall-clock is optional metadata**  
   Absolute timestamps may be stored when available, but they are advisory only and must not drive core pipeline logic.

3. **Timeline-centric architecture**  
   No model “owns” time. Each service emits objects onto the same shared timeline.

4. **Typed references and lineage**  
   Objects reference streams, artifacts, and other objects through typed refs. Derived and fused objects maintain explicit lineage.

5. **Deterministic before narrative**  
   Specialist model outputs are normalized and fused deterministically before any narrative summarization step.

6. **Confidence is derived**  
   Reliability is represented through a pipeline-level confidence model, not by assuming every source model exposes native confidence.

## Object model

The schema distinguishes between root records and timeline object families.

### Root records

- `capture_session`
- `sensor_stream`
- `artifact`

### Timeline object families

- `observation`
- `evidence`
- `derived`
- `fusion`

### Capture roots

- **CaptureSession**  
  Defines one session and optional advisory wall-clock metadata.

- **SensorStream**  
  Defines one microphone stream for that session.

- **Artifact**  
  Defines stored media files, raw model outputs, transcripts, embeddings, feature shards, and other materialized outputs.

### Timeline objects

- **Observation**  
  Baseline timeline observations, such as:
  - DSP bins

- **Evidence**  
  Direct outputs from upstream models, such as:
  - ASR words and segments
  - ASR corrections
  - acoustic context windows
  - diarization segments
  - speaker identification outputs
  - emotion windows and segments
  - sound event segments

- **Derived**  
  Deterministic products built from earlier objects, such as:
  - context segments
  - context change markers
  - quality bins

- **Fusion**  
  Final fused intervals intended for downstream interpretation and narrative summary.

## Time model

The schema uses relative time only for core pipeline behavior.

Supported temporal types:

- `RelativeInstant`
- `RelativeSpan`

All timing is expressed in seconds from session start.

## Canonical grids

The schema currently standardizes two grids:

- `audio_base_500ms`
  - regular bins
  - 0.5 second bin size

- `audio_context_30s_15s`
  - sliding windows
  - 30 second window size
  - 15 second hop size

Objects may reference a grid when they are generated on a declared binning or windowing scheme.

## Confidence and quality

Confidence is represented by `ConfidenceBundle`.

Important rule:
- native model outputs may exist, but they are not the same thing as fused pipeline confidence

`QualityBin` is the canonical derived object for dense quality and usability scoring on the timeline.

Reserved quality metric keys:

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

Extensions are allowed only with:
- `x_`
- `custom:`

## Lineage and references

The schema distinguishes between primary lineage and role-specific links.

### Primary lineage

- `derived_from`
- `fused_from`

These are the canonical semantic parent links for derived and fused objects.

### Role-specific links

Examples:
- `word_refs`
- `applies_to`
- `supporting_objects`
- `left_object`
- `right_object`
- `context_segment`

These are convenience links that provide additional structure, but they do not replace primary lineage.

All cross-object relationships must use typed refs:
- `StreamRef`
- `ArtifactRef`
- `ObjectRef`

## Validation

`SessionBundle` is the canonical container.

It validates:

- duplicate stream IDs
- duplicate artifact IDs
- duplicate object IDs
- session consistency across all contained objects
- stream reference integrity
- artifact reference integrity
- object reference integrity
- expected role / kind / timeline-family assertions
- timebase reference stream validity

Optional non-core temporal containment validation is also available when enough duration information is present.

## Current proposed services

The schema is designed around the following current service proposal.

### Stage 0: Session, stream, and artifact intake

These components establish the canonical session container and the raw audio artifact inputs:

- **Capture session / stream registration**
  - Creates the `CaptureSession` and `SensorStream`

- **Artifact ingestion**
  - Registers raw audio, raw model outputs, transcripts, embeddings, feature shards as `Artifact` records

### Stage 1: Baseline observations and broad context evidence

These services create the first timeline-aligned layers before higher-level derivation and fusion:

- **DSP service**
  - Produces 500 ms low-level acoustic observations
  - Emits `AudioDspBinObservation` objects on `audio_base_500ms`

- **General audio understanding**
  - `Qwen/Qwen2.5-Omni-7B`
  - Produces acoustic-context-window summaries, acoustic scene tags, and sound event tags
  - Emits `AudioContextWindowEvidence` objects on `audio_context_30s_15s`

### Stage 2: Specialist evidence generation

These services produce direct model evidence projected onto the same relative timeline:

- **ASR**
  - `parakeet-0.6b-tdt`
  - Produces ASR words and segments

- **ASR correction**
  - `Qwen/Qwen3-14B-AWQ`
  - Corrects domain spellings and transcript normalization

- **Diarization**
  - `BUT-FIT/diarizen-wavlm-large-s80-md-v2`
  - Produces speaker-attributed segments

- **Speaker identification**
  - `nvidia/speakerverification_en_titanet_large`
  - Produces speaker identification outputs for diarized regions

- **Emotion classification**
  - `3loi/SER-Odyssey-Baseline-WavLM-Categorical`
  - Produces categorical emotion evidence

- **Emotion dimensions**
  - `3loi/SER-Odyssey-Baseline-WavLM-Multi-Attributes`
  - Produces arousal, valence, and dominance evidence

- **Sound event detection**
  - `atst_as2M.ckpt + Stage2_wo_ext.ckpt`
  - Produces sound event segments

### Stage 3: Projection and normalization

This stage converts upstream service outputs into canonical schema objects:

- **Timeline projection / normalization**
  - Normalizes upstream outputs into canonical schema objects
  - Attaches typed refs, artifacts, temporal spans, and canonical lineage

### Stage 4: Derived context and quality

This stage builds deterministic higher-level timeline products from observations and evidence:

- **Baseline context service**
  - Produces context segments and context change markers from acoustic context windows and timeline evidence

- **Quality / usability / confidence service**
  - Produces quality bins and fused confidence bundles

### Stage 5: Final interval fusion and narrative

This stage produces the final human-usable interval layer:

- **Fusion / narrative service**
  - Produces `FusedInterval` objects and narrative summaries

## Proposed pipeline progression

At a high level, the intended progression through the pipeline is:

1. **Ingest session, stream, and raw audio artifacts**
2. **Generate baseline observations and broad context evidence**
   - DSP bins on the dense 500 ms grid
   - acoustic context windows on the 30 s / 15 s grid
3. **Generate specialist evidence**
   - ASR, transcript correction, diarization, speaker identification, emotion, and sound events
4. **Normalize all upstream outputs into canonical schema objects**
5. **Derive higher-level context**
   - context segments
   - context change markers
   - quality bins
6. **Fuse meaningful intervals**
   - combine transcript, speaker, emotion, sound events, and context into final fused intervals
7. **Produce narrative summaries**
   - emit concise interval-level interpretations and uncertainty notes

This progression is intentional:
- observations establish the baseline low-level timeline layer
- evidence adds direct model outputs
- derived objects capture deterministic higher-level structure
- fusion produces the final interpretive interval layer

## Hardware model

The current proposal assumes a local multi-service pipeline where heavy model services run with dedicated GPU access. Our dev environments will be designed specifically to run well locally on a single **NVIDIA RTX PRO 4000 Blackwell**.

### Intended operating assumptions

- minimal FastAPI services
- synchronized so that one service runs at a time
- no concurrency required inside a service
- each model service may assume full access to the GPU assigned to it
- orchestration, validation, storage, and bundle assembly may run on CPU

### Practical mapping

GPU-oriented services:
- ASR
- ASR correction
- diarization
- speaker identification
- emotion services
- sound event detection
- Qwen audio understanding
- fusion / narrative, if LLM-backed

CPU-friendly services:
- schema validation
- object normalization
- bundle assembly
- reference integrity checks
- artifact indexing
- some DSP workloads, depending on implementation

The schema itself is hardware-agnostic, but it is designed for this dedicated-service, dedicated-GPU deployment pattern.

## What is intentionally out of scope for now

This version of the schema is intentionally narrow.

Not yet modeled as first-class operational scope:
- video
- GPS
- IMU
- BLE
- phone state
- calendar feeds
- multimodal sensor fusion beyond audio
- enhancement as a core schema object family

These may be added later without changing the core timing and lineage principles.

## Contract summary

This schema is the single source of truth for:

- relative timeline representation
- canonical grid usage
- typed reference structure
- object lineage semantics
- quality vocabulary
- bundle integrity rules
- cross-service interoperability

## Implementation guidance

When implementing services against this schema:

1. Treat relative offsets as authoritative.
2. Emit typed refs, not raw IDs.
3. Store full raw outputs as artifacts when needed.
4. Use `native_outputs` only for small inline model-native values.
5. Use `derived_from` and `fused_from` as canonical lineage.
6. Keep payload-level refs role-specific and secondary.
7. Validate bundles aggressively.
8. Use reserved quality keys unless explicitly extending them.

## Status

This schema is intended to be the canonical contract for the current wrist-audio pipeline phase.
