# API_PLANNING.md

## Constraints

Single-host offline wrist-audio pipeline for compressed `.opus` inputs up to 5 hours.

- One machine, local HTTP only.
- One NVIDIA RTX Pro Blackwell 4000 (24 GB VRAM).
- Job-based execution only; no long blocking requests.
- Inputs are artifact refs, not large inline payloads.
- Outputs are artifacts plus canonical bundle updates.
- Relative offsets are the only operational timeline.
- v1 is strictly sequential.
- Only one GPU service runs at a time.
- The orchestrator enforces ordering, resumability, and skip-if-complete behavior.

Media rules:

- Keep the original `.opus` as the primary media artifact.
- Services decode internally as needed.
- Do not require a full-session pre-decoded WAV.
- Every service must process incrementally.
- No service may assume the full waveform fits in memory.
- Every stage must be restartable and idempotent for the same inputs and config.

## Stage order

| # | Stage | Service | HW | Blocks |
|---|---|---|---|---|
| 1 | Register input | Ingest | CPU | all downstream stages |
| 2 | Extract signal features | DSP | CPU | projection, baseline context, quality, fusion |
| 3 | Transcribe speech | ASR | GPU | ASR correction, projection, fusion |
| 4 | Segment speakers | Diarization | GPU | speaker ID, emotion, projection, fusion |
| 5 | Resolve speakers | Speaker ID | GPU | fusion |
| 6 | Correct transcript | ASR correction | GPU | fusion |
| 7 | Detect environment events | SED | GPU | projection, quality, fusion |
| 8 | Build coarse context windows | Context windows | GPU | baseline context, projection, fusion |
| 9 | Detect speech affect | Emotion | GPU | projection, quality, fusion |
| 10 | Normalize outputs | Timeline projection | CPU | baseline context, quality, fusion |
| 11 | Merge weak context | Baseline context | CPU | fusion |
| 12 | Score reliability | Quality | CPU | fusion |
| 13 | Assemble final intervals | Fusion | CPU | narrative |
| 14 | Write summaries | Narrative | CPU initially | final output |

GPU services run under one global lock.

Recommended initial GPU order:

1. ASR
2. Diarization
3. Speaker ID
4. ASR correction
5. SED
6. Context windows
7. Emotion

For long files:

- Services process internally in chunks.
- Chunking is invisible downstream.
- All offsets stay on the full-session relative timeline.
- Services should emit coarse progress.
- Partial outputs may be written during execution and finalized later.

## Service contracts

### Service matrix

| Service | Model / implementation | Purpose | Inputs | Outputs | HW | Notes |
|---|---|---|---|---|---|---|
| Ingest | local app service | Register session, stream, and primary artifact | raw `.opus`, optional metadata | session record, stream record, primary artifact | CPU | first stage only |
| DSP | custom DSP | Dense 500 ms low-level signal features | primary audio artifact | DSP bins, optional feature shard artifact | CPU | must stream incrementally |
| ASR | `parakeet-tdt` | Transcript evidence | primary audio artifact | word/phrase transcript evidence, transcript artifact | GPU | supports word boosting |
| Diarization | `BUT-FIT/diarizen-wavlm-large-s80-md-v2` | Speaker-homogeneous spans | primary audio artifact | diarization span evidence | GPU | basis for speaker-aware emotion |
| Speaker ID | `titanet` | Map speakers to enrolled identities | diarization spans, audio, enrolled speakers | speaker identity claims | GPU | optional if no enrollment |
| ASR correction | `Qwen/Qwen3-14B-AWQ` | Correct spelling and normalize transcript spans | transcript phrases, optional domain hints | correction evidence, optional corrected transcript artifact | GPU | must preserve original ASR text |
| SED | `atst_as2M.ckpt` + `Stage2_wo_ext.ckpt` | Non-speech and environment events | primary audio artifact | SED event spans, optional native output artifact | GPU | context layer only |
| Context windows | `Qwen/Qwen2.5-Omni-7B` | Coarse semantic scene windows | primary audio artifact, fixed 30 s / 15 s windows | context observations, optional raw output artifact | GPU | broad prior, not final segmentation |
| Emotion | `3loi/SER-Odyssey-Baseline-WavLM-Categorical` + `3loi/SER-Odyssey-Baseline-WavLM-Multi-Attributes` | Emotional evidence for speech | audio artifact, preferably diarized spans | emotion windows, optional decoded emotion segments | GPU | best after diarization |
| Timeline projection | custom projection service | Convert upstream outputs into canonical objects | DSP, ASR, diarization, speaker ID, SED, context, emotion outputs | canonical objects and refs | CPU | integration layer |
| Baseline context | custom baseline-context service | Merge weak context into longer scene segments | DSP bins, context windows, projected evidence density | context segments, context change markers | CPU | not full fusion |
| Quality | custom scoring service | Score suitability and reliability by timeline bin | DSP, projected evidence, context segments | quality bins, updated confidence bundles | CPU | cross-cutting layer |
| Fusion | custom fusion service | Build final intervals from all evidence | projected evidence, context segments, quality bins | fusion spans | CPU | deterministic first |
| Narrative | custom formatter, optionally LLM-backed later | Convert fusion spans into concise summaries | fusion spans | final summaries, optional narrative artifact | CPU initially | keep simple first |

### Common API

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Ready only when the service is actually usable |
| GET | `/info` | Service name, model/version, expected inputs, outputs, config defaults |
| POST | `/v1/jobs` | Start a job from artifact refs and optional object refs |
| GET | `/v1/jobs/{job_id}` | Poll status, progress, warnings, emitted counts |
| GET | `/v1/jobs/{job_id}/result` | Return result manifest |
| POST | `/v1/jobs/{job_id}/cancel` | Optional clean cancellation |

### Job request

| Field | Meaning |
|---|---|
| `session_id` | target session |
| `input_artifact_ids` | source artifacts |
| `input_object_ids` | optional upstream objects |
| `config` | service-specific overrides |
| `idempotency_key` | dedupe repeated calls |
| `output_root` | optional local output hint |

### Job result

| Field | Meaning |
|---|---|
| `job_id` | stable job identifier |
| `status` | `completed`, `completed_with_warnings`, or `failed` |
| `created_artifact_ids` | new artifacts |
| `created_object_count` | canonical object count |
| `warnings` | non-fatal issues |
| `errors` | fatal issues if failed |
| `model_version` | exact model/build used |
| `config_hash` | exact run config identity |

## Failure and build policy

A failed stage must not erase earlier successful work.

| Failure | Preserve | Continue with |
|---|---|---|
| ASR correction | raw ASR | uncorrected transcript |
| Speaker ID | diarization | anonymous speaker labels |
| Emotion | all other evidence | reduced affect coverage |
| Context windows | DSP, SED, ASR, diarization | degraded or skipped baseline context |
| SED | all speech layers | weaker scene interpretation |

Build order:

1. Ingest
2. DSP
3. ASR
4. Diarization
5. Timeline projection
6. Context windows
7. Baseline context
8. SED
9. Emotion
10. Quality
11. Fusion
12. Narrative
13. Speaker ID
14. ASR correction

Implementation guidance:

- Start with local filesystem artifacts plus SQLite metadata.
- Prefer one service per container or process.
- Prioritize sequential correctness over orchestration complexity.
- Make every stage resumable.
- Keep raw outputs for debugging.
- Normalize everything before fusion.
- Treat the system as a single-host offline analysis appliance, not a distributed platform.
