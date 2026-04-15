# API_PLANNING.md

This document defines pipeline orchestration: stage order, service boundaries, job APIs, failure behavior, and operational constraints.

Canonical data semantics, lineage rules, and payload meaning are defined in `SCHEMA.md`.

## Constraints

Single-host offline wrist-audio pipeline for compressed `.opus` inputs up to 5 hours.

- One machine, local HTTP only.
- One NVIDIA RTX Pro Blackwell 4000 (24 GB VRAM).
- Job-based execution only; no long blocking requests.
- Jobs are started from artifact IDs and optional object IDs within a session, not from large inline payloads.
- Outputs are artifacts plus canonical bundle updates.
- Relative offsets and explicit timebases are the only operational timeline.
- v1 is strictly sequential.
- Only one GPU service runs at a time.
- The orchestrator enforces ordering, resumability, idempotency, and skip-if-complete behavior.

Media rules:

- Keep the original `.opus` as the primary-media artifact.
- Services decode internally as needed.
- Do not require a full-session pre-decoded WAV.
- Every service must process incrementally.
- No service may assume the full waveform fits in memory.
- Every stage must be restartable and idempotent for the same inputs and config.

Canonical planning conventions:

- Ingest creates the root records: `capture_session`, `sensor_stream`, and the primary-media `artifact`.
- Upstream extraction services produce service-native outputs and artifacts.
- `ASR correction`, `Emotion`, `Speaker identification`, `DASM probe`, `Text-corpus candidate search`, and `Song identification` are targeted stages. They run only on upstream-surfaced candidates and may be skipped entirely when no viable candidates exist.
- `Timeline projection` is the step that materializes canonical timeline objects from the available upstream outputs.
- `Baseline context`, `Quality`, `Fusion`, and `Narrative` run strictly after projection.
- Relative time remains authoritative throughout. Wall-clock estimates are advisory only and must not drive orchestration.
- The canonical grid IDs used in v1 are `audio_base_500ms` and `audio_context_30s_15s`.

## Execution order

This is the authoritative v1 stage order and build order.

| # | Stage | Service | HW | Depends on | Canonical effect | Blocks |
|---|---|---|---|---|---|---|
| 1 | Register input | Ingest | CPU | none | registers root records | all downstream stages |
| 2 | Extract signal features | DSP | CPU | Ingest | service-native outputs only | Timeline projection, Baseline context, Quality, Fusion |
| 3 | Transcribe speech | ASR | GPU | Ingest | service-native outputs only | ASR correction, Timeline projection, Quality, Fusion |
| 4 | Segment speakers | Diarization | GPU | Ingest | service-native outputs only | Emotion, Speaker identification, Timeline projection, Quality, Fusion |
| 5 | Detect environment events | SED | GPU | Ingest | service-native outputs only | Timeline projection, Baseline context, Quality, Fusion |
| 6 | Build coarse context windows | Context windows | GPU | Ingest | service-native outputs only | Timeline projection, Baseline context, Fusion |
| 7 | Detect speech affect | Emotion | GPU | Diarization | service-native outputs only | Timeline projection, Quality, Fusion |
| 8 | Resolve speakers | Speaker identification | GPU | Diarization | service-native outputs only | Timeline projection, Fusion |
| 9 | Correct transcript | ASR correction | GPU | ASR | service-native outputs only | Text-corpus candidate search, Timeline projection, Fusion |
| 10 | Probe candidate non-speech and media spans | DASM probe | GPU | SED | service-native outputs only | Timeline projection, Quality, Fusion |
| 11 | Search text corpora for candidate media matches | Text-corpus candidate search | CPU | ASR, SED, optional ASR correction | service-native outputs only | Song identification, Timeline projection, Fusion |
| 12 | Confirm candidate released songs | Song identification | CPU | SED, Text-corpus candidate search | service-native outputs only | Timeline projection, Fusion |
| 13 | Project to canonical timeline objects | Timeline projection | CPU | DSP, ASR, Diarization, SED, Context windows, optional Emotion, optional Speaker identification, optional ASR correction, optional DASM probe, optional Text-corpus candidate search, optional Song identification | materializes canonical observation and evidence objects | Baseline context, Quality, Fusion |
| 14 | Merge broad context into durable segments | Baseline context | CPU | Timeline projection | materializes derived context objects | Quality, Fusion |
| 15 | Score reliability and usability | Quality | CPU | Timeline projection, Baseline context | materializes quality objects | Fusion |
| 16 | Build durable downstream intervals | Fusion | CPU | Timeline projection, Baseline context, Quality | materializes fusion objects | Narrative, final output |
| 17 | Write narrative summaries | Narrative | CPU initially | Fusion | enriches fused intervals | final output |

GPU services run under one global lock.

Recommended initial GPU order:

1. ASR
2. Diarization
3. SED
4. Context windows
5. Emotion
6. Speaker identification
7. ASR correction
8. DASM probe

Notes on the recommended GPU order:

- ASR and Diarization run first because they unlock the largest set of dependent stages.
- SED and Context windows are independent broad-context passes that only need the primary-media artifact.
- Emotion runs after Diarization because diarized speech spans are the intended candidates for speech-affect evidence.
- Speaker identification is optional and depends on Diarization plus enrollment.
- ASR correction is optional and depends on ASR. It runs before `Text-corpus candidate search` and Timeline projection so corrected transcript evidence is available downstream.
- DASM probe is optional but high-value. It runs only on SED-gated candidate spans, never as an unconstrained whole-file scan.
- `Text-corpus candidate search` is CPU-light once a local index exists. It runs after SED and transcript production so it can add media-oriented evidence from subtitle and lyric corpora.
- `Song identification` is a cheap confirmation stage for music candidates surfaced by SED plus text-corpus search.

For long files:

- Services process internally in chunks.
- Chunking is invisible downstream.
- All offsets stay on the full-session relative timeline.
- Services should emit coarse progress.
- Partial outputs may be written during execution and finalized later.

## Service contracts

### Service matrix

| Service | Model / implementation | Purpose | Inputs | Native outputs / artifacts | Canonical objects after projection | HW | Notes |
|---|---|---|---|---|---|---|---|
| Ingest | local app service | Register session, stream, and primary media | raw `.opus`, optional metadata | root records and primary-media artifact | `capture_session`, `sensor_stream`, primary-media `artifact` | CPU | first stage only |
| DSP | custom DSP | Dense 500 ms low-level signal features | primary-media artifact | DSP feature stream, optional `feature_shard` artifact | `audio_dsp_bin_observation` | CPU | must stream incrementally; uses canonical grid `audio_base_500ms` |
| ASR | `parakeet-0.6b-tdt` | Transcript evidence | primary-media artifact | transcript artifact, word/segment native outputs | `audio_asr_word_evidence`, `audio_asr_segment_evidence` | GPU | supports word boosting |
| Diarization | `BUT-FIT/diarizen-wavlm-large-s80-md-v2` | Speaker-homogeneous spans | primary-media artifact | diarization native outputs | `audio_diarization_segment_evidence` | GPU | basis for speaker-aware emotion and speaker identification |
| SED | `FrameATST` | Non-speech and environment events | primary-media artifact | sound-event native outputs, optional `native_output` artifact | `audio_sound_event_segment_evidence` | GPU | context layer only |
| Context windows | `MiDashengLM-0.6B via vLLM` | Coarse semantic scene windows | primary-media artifact, fixed 30 s / 15 s windows | context-window native outputs, optional raw-output artifact | `audio_context_window_evidence` | GPU | broad prior, not final segmentation; uses canonical grid `audio_context_30s_15s` |
| Emotion | `3loi/SER-Odyssey-Baseline-WavLM-Categorical` + `3loi/SER-Odyssey-Baseline-WavLM-Multi-Attributes` | Emotional evidence for speech | primary-media artifact, diarized speech spans | emotion native outputs, optional decoded emotion artifact | `audio_emotion_window_evidence`, optionally `audio_emotion_segment_evidence` | GPU | targeted to diarized speech spans |
| Speaker identification | `nvidia/speakerverification_en_titanet_large` | Map speakers to enrolled identities | diarization outputs, primary-media artifact, enrolled speakers | speaker-identification native outputs | `audio_speaker_identification_evidence` | GPU | optional if no enrollment |
| ASR correction | `Qwen/Qwen3-14B-AWQ` | Correct spelling and normalize transcript spans | ASR outputs, optional domain hints | correction native outputs, optional corrected transcript artifact | `audio_asr_correction_evidence` | GPU | must preserve original ASR text |
| DASM probe | DASM or equivalent open-vocabulary query-conditioned frame-level SED | Refine candidate non-speech and media intervals with targeted text or audio queries | SED outputs, primary-media artifact, configured text queries and/or query audio artifacts | query-conditioned probe outputs, optional `native_output` artifact | `audio_query_conditioned_sound_evidence` | GPU | gated refinement only; do not whole-file scan |
| Text-corpus candidate search | local subtitle/lyric/text index (for example OpenSubtitles and WASABI-derived corpora) | Search short transcript queries against large local corpora to add media candidate evidence | ASR outputs or corrected transcript artifact, SED-gated candidate intervals | corpus-match outputs, optional `auxiliary` artifact | `audio_text_corpus_match_evidence` | CPU | high-value once a local index exists; query path is lightweight |
| Song identification | Chromaprint or equivalent local fingerprint matcher | Confirm released-song matches for candidate music intervals | primary-media artifact, SED-gated music candidates, text-corpus candidate matches | song-identification outputs, optional `auxiliary` artifact | `audio_song_identification_evidence` | CPU | cheap confirmation stage; best after SED plus text-corpus search |
| Timeline projection | custom projection service | Convert upstream outputs into canonical timeline objects and typed refs | DSP, ASR, Diarization, SED, Context windows, optional Emotion, optional Speaker identification, optional ASR correction, optional DASM probe, optional Text-corpus candidate search, optional Song identification outputs | canonical bundle updates | `audio_dsp_bin_observation`, `audio_context_window_evidence`, `audio_asr_word_evidence`, `audio_asr_segment_evidence`, `audio_asr_correction_evidence`, `audio_diarization_segment_evidence`, `audio_speaker_identification_evidence`, `audio_emotion_window_evidence`, `audio_emotion_segment_evidence`, `audio_sound_event_segment_evidence`, `audio_query_conditioned_sound_evidence`, `audio_text_corpus_match_evidence`, `audio_song_identification_evidence` | CPU | integration layer; preserves typed refs, lineage, timebase, grid semantics |
| Baseline context | custom baseline-context service | Merge broad weak context into longer durable scene structure | projected observations/evidence, especially DSP bins and context-window evidence | canonical bundle updates | `context_segment`, `context_change_marker` | CPU | derived layer only; not full fusion |
| Quality | custom scoring service | Score suitability and reliability by timeline bin | projected observations/evidence, context segments | canonical bundle updates | `quality_bin` and optional confidence updates on existing objects | CPU | uses reserved quality metric and usability vocabularies, including `media` when supported |
| Fusion | custom fusion service | Build durable downstream interpretation intervals | projected observations/evidence, context segments, quality bins | canonical bundle updates | `fused_interval` | CPU | deterministic first; may summarize detected playback or identified media such as songs, movies, television, or radio when evidence is sufficient |
| Narrative | custom formatter, optionally LLM-backed later | Add concise summaries and review signals to fused intervals | `fused_interval` objects | updated fused intervals, optional narrative artifact | updates `fused_interval.narrative` and optional artifact | CPU initially | keep simple first |

### Common API

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Ready only when the service is actually usable |
| GET | `/info` | Service name, model/version, expected inputs, outputs, config defaults |
| POST | `/v1/jobs` | Start a job from artifact IDs and optional object IDs within a session |
| GET | `/v1/jobs/{job_id}` | Poll status, progress, warnings, emitted counts |
| GET | `/v1/jobs/{job_id}/result` | Return result manifest |
| POST | `/v1/jobs/{job_id}/cancel` | Optional clean cancellation |

### Job request

| Field | Meaning |
|---|---|
| `session_id` | target session |
| `input_artifact_ids` | source artifact IDs |
| `input_object_ids` | optional upstream object IDs |
| `config` | service-specific overrides |
| `idempotency_key` | dedupe repeated calls |
| `output_root` | optional local output hint |

### Job result

| Field | Meaning |
|---|---|
| `job_id` | stable job identifier |
| `status` | `completed`, `completed_with_warnings`, or `failed` |
| `created_artifact_ids` | newly created artifacts |
| `created_object_ids` | newly created canonical object IDs |
| `updated_object_ids` | canonical object IDs updated in place |
| `warnings` | non-fatal issues |
| `errors` | fatal issues if failed |
| `model_version` | exact model/build used |
| `config_hash` | exact run config identity |

## Failure policy

A failed stage must not erase earlier successful work.

| Failure | Preserve | Continue with |
|---|---|---|
| ASR correction | raw ASR evidence and transcript artifact | uncorrected transcript |
| Speaker identification | diarization evidence | anonymous speaker labels |
| Emotion | all other evidence | reduced affect coverage |
| DASM probe | SED evidence | coarser sound-event and media interpretation |
| Text-corpus candidate search | ASR evidence, optional corrected transcript artifact, SED evidence | weaker media-candidate evidence |
| Song identification | SED evidence and text-corpus match evidence | candidate music remains unidentified |
| Context windows | DSP, SED, ASR, diarization | degraded or skipped baseline context |
| SED | speech layers and transcript layers | weaker scene interpretation |

Additional policy:

- Optional stages may fail without invalidating the session bundle.
- Targeted stages must be skippable when their prerequisites do not surface viable candidates.
- Skipped, negative, or no-op targeted-stage attempts stay in job metadata, warnings, or artifacts.
- Timeline projection must be able to project the outputs that do exist and omit the ones that do not.
- Fusion must degrade gracefully when optional evidence families are absent.
- Narrative must never invent unsupported facts; it summarizes the current `fused_interval` state.

## Build policy

Build order is identical to the execution order above. v1 does not define a separate build graph.

Rationale:

- All raw upstream extraction stages complete before Timeline projection.
- Targeted evidence stages run after the broad candidate-producing stages they depend on and before Timeline projection.
- Projection produces the canonical observation/evidence layer once, from the full available upstream set.
- Derived stages (`Baseline context`, `Quality`) run only after the canonical observation/evidence layer exists.
- `Fusion` runs only after the derived context and quality layers exist.
- `Narrative` runs last because it enriches `fused_interval` rather than preceding it.

## Implementation guidance

- Start with local filesystem artifacts plus SQLite metadata.
- Prefer one service per container or process.
- Prioritize sequential correctness over orchestration complexity.
- Make every stage resumable and idempotent.
- Keep raw outputs for debugging.
- Preserve typed references, lineage, and timebase data during projection.
- Keep model-native values in native outputs and large raw outputs in artifacts.
- Normalize once, before any derived or fusion stage.
- Treat the system as a single-host offline analysis appliance, not a distributed platform.
