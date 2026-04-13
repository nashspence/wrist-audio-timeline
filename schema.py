from __future__ import annotations

from datetime import datetime, timedelta
from enum import StrEnum
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


SCHEMA_VERSION = "v1.0.0-alpha.1"


# ============================================================
# Canonical grid ids
# ============================================================

GRID_AUDIO_BASE_500MS = "audio_base_500ms"
GRID_AUDIO_CONTEXT_30S_15S = "audio_context_30s_15s"


# ============================================================
# Scalar aliases
# ============================================================

UnitScore = Annotated[float, Field(ge=0.0, le=1.0)]
NonNegativeFloat = Annotated[float, Field(ge=0.0)]


# ============================================================
# Reserved quality vocabulary
# ============================================================

QUALITY_METRIC_KEYS: set[str] = {
    "rms_dbfs",
    "estimated_snr_db",
    "speech_ratio",
    "overlap_risk",
    "boundary_risk",
    "asr_gap_density",
}

QUALITY_USABILITY_KEYS: set[str] = {
    "asr",
    "speaker",
    "emotion",
    "sound_event",
    "acoustic_scene",
    "overall",
}

QUALITY_EXTENSION_PREFIXES: tuple[str, ...] = ("x_", "custom:")


# ============================================================
# Enums
# ============================================================


class Severity(StrEnum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"


class TimelineObjectFamily(StrEnum):
    OBSERVATION = "observation"
    EVIDENCE = "evidence"
    DERIVED = "derived"
    FUSION = "fusion"


class Modality(StrEnum):
    AUDIO = "audio"


class StreamKind(StrEnum):
    MICROPHONE = "microphone"


class ArtifactRole(StrEnum):
    PRIMARY_MEDIA = "primary_media"
    FEATURE_SHARD = "feature_shard"
    NATIVE_OUTPUT = "native_output"
    TRANSCRIPT = "transcript"
    EMBEDDING = "embedding"
    AUXILIARY = "auxiliary"


class ArtifactFormat(StrEnum):
    WAV = "wav"
    FLAC = "flac"
    OPUS = "opus"
    MP3 = "mp3"
    AAC = "aac"
    PCM = "pcm"
    JSON = "json"
    NDJSON = "ndjson"
    CSV = "csv"
    PROTOBUF = "protobuf"
    PARQUET = "parquet"
    OTHER = "other"


class ClockSource(StrEnum):
    DEVICE_MONOTONIC = "device_monotonic"
    SERVER_INGEST = "server_ingest"
    MANUAL = "manual"
    DERIVED = "derived"


class WallClockEstimateSource(StrEnum):
    DEVICE_FILE_MTIME = "device_file_mtime"
    DEVICE_METADATA = "device_metadata"
    USER_DECLARED = "user_declared"
    SERVER_INGEST = "server_ingest"
    DERIVED = "derived"


class WallClockEstimateQuality(StrEnum):
    TRUSTED = "trusted"
    APPROXIMATE = "approximate"
    WEAK = "weak"
    GUESSED = "guessed"


class TimeKind(StrEnum):
    RELATIVE_INSTANT = "relative_instant"
    RELATIVE_SPAN = "relative_span"


class GridKind(StrEnum):
    REGULAR_BINS = "regular_bins"
    SLIDING_WINDOWS = "sliding_windows"
    OTHER = "other"


class SpeechPresence(StrEnum):
    PRIMARY = "primary"
    BACKGROUND = "background"
    INTERMITTENT = "intermittent"
    ABSENT = "absent"
    UNCERTAIN = "uncertain"


class CorrectionType(StrEnum):
    DOMAIN_SPELLING = "domain_spelling"
    NORMALIZATION = "normalization"
    OTHER = "other"


class ChangeType(StrEnum):
    ACOUSTIC_SCENE_SHIFT = "acoustic_scene_shift"
    ACOUSTIC_SHIFT = "acoustic_shift"
    SPEECH_DENSITY_SHIFT = "speech_density_shift"
    ACTIVITY_SHIFT = "activity_shift"
    UNCERTAIN = "uncertain"


class FusionKind(StrEnum):
    SPEAKER_TURN = "speaker_turn"
    CONVERSATION_INTERVAL = "conversation_interval"
    ACTIVITY_INTERVAL = "activity_interval"
    EPISODE_INTERVAL = "episode_interval"
    REVIEW_INTERVAL = "review_interval"


# ============================================================
# Shared helpers
# ============================================================


class StrictBaseModel(BaseModel):
    model_config = ConfigDict(
        extra="forbid",
        populate_by_name=True,
        use_enum_values=True,
        validate_assignment=True,
    )


class ReasonCode(StrictBaseModel):
    code: str
    severity: Severity
    message: str


class TagScore(StrictBaseModel):
    tag: str
    score: UnitScore


class ProvenanceRef(StrictBaseModel):
    source_service: str
    source_object_id: str
    source_kind: str
    weight: UnitScore | None = None


class ConfidenceBundle(StrictBaseModel):
    confidence_overall: UnitScore
    subscores: dict[str, UnitScore] = Field(default_factory=dict)
    confidence_basis: list[str] = Field(default_factory=list)
    reasons: list[ReasonCode] = Field(default_factory=list)


class TimebaseRef(StrictBaseModel):
    clock_source: ClockSource
    reference_stream_id: str | None = None
    alignment_uncertainty_ms: NonNegativeFloat | None = None
    sync_notes: str | None = None


class GridRef(StrictBaseModel):
    grid_id: str
    grid_kind: GridKind

    origin_offset_s: NonNegativeFloat = 0.0

    bin_size_s: float | None = Field(default=None, gt=0.0)
    window_size_s: float | None = Field(default=None, gt=0.0)
    hop_size_s: float | None = Field(default=None, gt=0.0)

    alignment_notes: str | None = None

    @model_validator(mode="after")
    def _validate_grid(self) -> "GridRef":
        if self.grid_kind == GridKind.REGULAR_BINS and self.bin_size_s is None:
            raise ValueError("bin_size_s is required for regular_bins")

        if self.grid_kind == GridKind.SLIDING_WINDOWS:
            if self.window_size_s is None:
                raise ValueError("window_size_s is required for sliding_windows")
            if self.hop_size_s is None:
                raise ValueError("hop_size_s is required for sliding_windows")

        return self


BASE_500MS_GRID = GridRef(
    grid_id=GRID_AUDIO_BASE_500MS,
    grid_kind=GridKind.REGULAR_BINS,
    origin_offset_s=0.0,
    bin_size_s=0.5,
)

CONTEXT_30S_15S_GRID = GridRef(
    grid_id=GRID_AUDIO_CONTEXT_30S_15S,
    grid_kind=GridKind.SLIDING_WINDOWS,
    origin_offset_s=0.0,
    window_size_s=30.0,
    hop_size_s=15.0,
)


class RelativeInstant(StrictBaseModel):
    time_kind: Literal[TimeKind.RELATIVE_INSTANT] = TimeKind.RELATIVE_INSTANT
    offset_s: NonNegativeFloat
    timebase: TimebaseRef


class RelativeSpan(StrictBaseModel):
    time_kind: Literal[TimeKind.RELATIVE_SPAN] = TimeKind.RELATIVE_SPAN
    start_offset_s: NonNegativeFloat
    end_offset_s: float = Field(gt=0.0)
    duration_s: float | None = Field(default=None, gt=0.0)
    center_offset_s: NonNegativeFloat | None = None
    timebase: TimebaseRef

    @model_validator(mode="after")
    def _validate_relative_span(self) -> "RelativeSpan":
        if self.end_offset_s <= self.start_offset_s:
            raise ValueError("end_offset_s must be greater than start_offset_s")
        duration_s = self.end_offset_s - self.start_offset_s
        object.__setattr__(self, "duration_s", duration_s)
        object.__setattr__(
            self,
            "center_offset_s",
            self.start_offset_s + (duration_s / 2.0),
        )
        return self


TemporalExtent = Annotated[
    RelativeInstant | RelativeSpan,
    Field(discriminator="time_kind"),
]


class AudioProperties(StrictBaseModel):
    sample_rate_hz: int = Field(gt=0)
    channel_count: int = Field(gt=0)


class StreamRef(StrictBaseModel):
    stream_id: str
    relation: str | None = None


class ArtifactStreamRef(StreamRef):
    is_primary: bool = False


class ArtifactRef(StrictBaseModel):
    artifact_id: str
    relation: str | None = None
    expected_role: ArtifactRole | None = None


class ObjectRef(StrictBaseModel):
    object_id: str
    relation: str | None = None
    expected_kind: str | None = None
    expected_family: TimelineObjectFamily | None = None


class WallClockEstimate(StrictBaseModel):
    timestamp_utc: datetime
    source: WallClockEstimateSource
    quality: WallClockEstimateQuality

    uncertainty_before_s: NonNegativeFloat = 0.0
    uncertainty_after_s: NonNegativeFloat = 0.0

    rationale: str | None = None
    supporting_artifact_refs: list[ArtifactRef] = Field(default_factory=list)

    @model_validator(mode="after")
    def _validate_timestamp_utc(self) -> "WallClockEstimate":
        if self.timestamp_utc.tzinfo is None or self.timestamp_utc.utcoffset() is None:
            raise ValueError("timestamp_utc must be timezone-aware")
        if self.timestamp_utc.utcoffset() != timedelta(0):
            raise ValueError("timestamp_utc must be normalized to UTC")
        return self

    @property
    def lower_bound_utc(self) -> datetime:
        return self.timestamp_utc - timedelta(seconds=self.uncertainty_before_s)

    @property
    def upper_bound_utc(self) -> datetime:
        return self.timestamp_utc + timedelta(seconds=self.uncertainty_after_s)

    @property
    def uncertainty_span_s(self) -> float:
        return self.uncertainty_before_s + self.uncertainty_after_s


# ============================================================
# Root records
# ============================================================


class CaptureSessionMetadata(StrictBaseModel):
    wearer_id: str | None = None
    timezone: str | None = None
    notes: str | None = None
    attributes: dict[str, Any] = Field(default_factory=dict)


class CaptureSession(StrictBaseModel):
    schema_version: str = Field(default=SCHEMA_VERSION)
    kind: Literal["capture_session"] = "capture_session"

    session_id: str
    duration_s: float | None = Field(default=None, gt=0.0)

    # Optional metadata only. Relative offsets remain canonical.
    wall_clock_start: WallClockEstimate | None = None
    wall_clock_candidates: list[WallClockEstimate] = Field(default_factory=list)

    metadata: CaptureSessionMetadata = Field(default_factory=CaptureSessionMetadata)


class SensorStreamMetadata(StrictBaseModel):
    source: str | None = None
    device_id: str | None = None
    mount_position: str | None = None
    notes: str | None = None
    attributes: dict[str, Any] = Field(default_factory=dict)


class SensorStream(StrictBaseModel):
    schema_version: str = Field(default=SCHEMA_VERSION)
    kind: Literal["sensor_stream"] = "sensor_stream"

    stream_id: str
    session_id: str

    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    stream_kind: Literal[StreamKind.MICROPHONE] = StreamKind.MICROPHONE
    name: str | None = None

    duration_s: float | None = Field(default=None, gt=0.0)
    nominal_sample_rate_hz: float | None = Field(default=None, gt=0.0)

    timebase: TimebaseRef
    audio: AudioProperties
    metadata: SensorStreamMetadata = Field(default_factory=SensorStreamMetadata)


class ArtifactMetadata(StrictBaseModel):
    attributes: dict[str, Any] = Field(default_factory=dict)


class Artifact(StrictBaseModel):
    schema_version: str = Field(default=SCHEMA_VERSION)
    kind: Literal["artifact"] = "artifact"

    artifact_id: str
    session_id: str
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    stream_refs: list[ArtifactStreamRef] = Field(default_factory=list)

    artifact_role: ArtifactRole
    uri: str
    sha256: str | None = None
    mime_type: str | None = None
    artifact_format: ArtifactFormat | None = None
    byte_size: int | None = Field(default=None, ge=0)

    start_offset_s: NonNegativeFloat | None = None
    end_offset_s: NonNegativeFloat | None = None

    audio: AudioProperties | None = None
    metadata: ArtifactMetadata = Field(default_factory=ArtifactMetadata)

    @model_validator(mode="after")
    def _validate_artifact(self) -> "Artifact":
        if (
            self.start_offset_s is not None
            and self.end_offset_s is not None
            and self.end_offset_s <= self.start_offset_s
        ):
            raise ValueError("end_offset_s must be greater than start_offset_s")

        if len({ref.stream_id for ref in self.stream_refs}) != len(self.stream_refs):
            raise ValueError("artifact stream_refs must not repeat the same stream_id")

        if sum(1 for ref in self.stream_refs if ref.is_primary) > 1:
            raise ValueError("artifact stream_refs may mark at most one primary stream")

        return self


# ============================================================
# Timeline object base classes
# ============================================================


class TimelineObjectBase(StrictBaseModel):
    schema_version: str = Field(default=SCHEMA_VERSION)
    object_id: str
    session_id: str

    family: TimelineObjectFamily
    kind: str
    modality: Modality

    stream_refs: list[StreamRef] = Field(default_factory=list)
    artifact_refs: list[ArtifactRef] = Field(default_factory=list)

    temporal: TemporalExtent
    grid: GridRef | None = None

    def outbound_object_refs(self) -> list[ObjectRef]:
        return []

    def outbound_artifact_refs(self) -> list[ArtifactRef]:
        return list(self.artifact_refs)

    def outbound_stream_refs(self) -> list[StreamRef]:
        return list(self.stream_refs)


class ObservationBase(TimelineObjectBase):
    family: Literal[TimelineObjectFamily.OBSERVATION] = TimelineObjectFamily.OBSERVATION

    source_service: str
    source_model: str | None = None

    native_outputs: dict[str, Any] = Field(default_factory=dict)
    raw_output_artifact_refs: list[ArtifactRef] = Field(default_factory=list)
    service_metadata: dict[str, Any] = Field(default_factory=dict)

    confidence: ConfidenceBundle
    provenance: list[ProvenanceRef] = Field(default_factory=list)

    def outbound_artifact_refs(self) -> list[ArtifactRef]:
        return [*self.artifact_refs, *self.raw_output_artifact_refs]


class EvidenceBase(TimelineObjectBase):
    family: Literal[TimelineObjectFamily.EVIDENCE] = TimelineObjectFamily.EVIDENCE

    source_service: str
    source_model: str | None = None

    attributes: dict[str, Any] = Field(default_factory=dict)
    native_outputs: dict[str, Any] = Field(default_factory=dict)
    raw_output_artifact_refs: list[ArtifactRef] = Field(default_factory=list)
    service_metadata: dict[str, Any] = Field(default_factory=dict)

    confidence: ConfidenceBundle
    provenance: list[ProvenanceRef] = Field(default_factory=list)

    def outbound_artifact_refs(self) -> list[ArtifactRef]:
        return [*self.artifact_refs, *self.raw_output_artifact_refs]


class DerivedBase(TimelineObjectBase):
    family: Literal[TimelineObjectFamily.DERIVED] = TimelineObjectFamily.DERIVED

    source_service: str = "timeline_derivation_service"

    # Primary semantic parent links.
    derived_from: list[ObjectRef] = Field(default_factory=list)
    attributes: dict[str, Any] = Field(default_factory=dict)

    confidence: ConfidenceBundle
    provenance: list[ProvenanceRef] = Field(default_factory=list)

    def outbound_object_refs(self) -> list[ObjectRef]:
        return list(self.derived_from)


class FusionBase(TimelineObjectBase):
    family: Literal[TimelineObjectFamily.FUSION] = TimelineObjectFamily.FUSION

    source_service: str = "timeline_fusion_service"

    # Primary semantic parent links.
    fused_from: list[ObjectRef] = Field(default_factory=list)
    confidence: ConfidenceBundle
    provenance: list[ProvenanceRef] = Field(default_factory=list)

    def outbound_object_refs(self) -> list[ObjectRef]:
        return list(self.fused_from)


# ============================================================
# Audio observations and broad context evidence
# ============================================================


class AudioDspBinPayload(StrictBaseModel):
    rms_dbfs: float | None = None
    peak_dbfs: float | None = None
    crest_factor_db: float | None = None
    dynamic_range_db: float | None = None
    clipping_fraction: UnitScore | None = None
    zero_crossing_rate: UnitScore | None = None

    spectral_centroid_hz: NonNegativeFloat | None = None
    spectral_rolloff_hz: NonNegativeFloat | None = None
    spectral_bandwidth_hz: NonNegativeFloat | None = None

    low_freq_ratio: UnitScore | None = None
    mid_freq_ratio: UnitScore | None = None
    high_freq_ratio: UnitScore | None = None

    estimated_snr_db: float | None = None
    voiced_ratio: UnitScore | None = None
    speech_ratio: UnitScore | None = None
    silence_ratio: UnitScore | None = None


class AudioContextWindowPayload(StrictBaseModel):
    short_caption: str | None = None
    detailed_summary: str | None = None
    acoustic_scene_tags: list[TagScore] = Field(default_factory=list)
    sound_event_tags: list[TagScore] = Field(default_factory=list)
    speech_presence: SpeechPresence | None = None
    uncertainty_notes: list[str] = Field(default_factory=list)
    groundedness_score: UnitScore | None = None


class AudioDspBinObservation(ObservationBase):
    kind: Literal["audio_dsp_bin_observation"] = "audio_dsp_bin_observation"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: AudioDspBinPayload


class AudioContextWindowEvidence(EvidenceBase):
    kind: Literal["audio_context_window_evidence"] = "audio_context_window_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: AudioContextWindowPayload


# ============================================================
# Audio evidence
# ============================================================


class AsrWordPayload(StrictBaseModel):
    text: str
    normalized_text: str | None = None
    speaker_label: str | None = None


class AsrSegmentPayload(StrictBaseModel):
    text: str
    normalized_text: str | None = None
    word_refs: list[ObjectRef] = Field(default_factory=list)
    speaker_label: str | None = None


class AsrCorrectionPayload(StrictBaseModel):
    original_text: str
    corrected_text: str
    correction_type: CorrectionType
    applies_to: list[ObjectRef] = Field(default_factory=list)


class DiarizationSegmentPayload(StrictBaseModel):
    speaker_label: str
    overlap: bool = False


class SpeakerIdentificationPayload(StrictBaseModel):
    speaker_label: str
    speaker_identity: str | None = None


class EmotionWindowPayload(StrictBaseModel):
    categorical: list[TagScore] = Field(default_factory=list)
    arousal: float | None = None
    valence: float | None = None
    dominance: float | None = None
    speaker_label: str | None = None


class EmotionSegmentPayload(StrictBaseModel):
    label: str | None = None
    arousal_mean: float | None = None
    valence_mean: float | None = None
    dominance_mean: float | None = None
    speaker_label: str | None = None


class SoundEventSegmentPayload(StrictBaseModel):
    event_label: str
    event_score: UnitScore | None = None


class AudioAsrWordEvidence(EvidenceBase):
    kind: Literal["audio_asr_word_evidence"] = "audio_asr_word_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: AsrWordPayload


class AudioAsrSegmentEvidence(EvidenceBase):
    kind: Literal["audio_asr_segment_evidence"] = "audio_asr_segment_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: AsrSegmentPayload

    def outbound_object_refs(self) -> list[ObjectRef]:
        return [*super().outbound_object_refs(), *self.payload.word_refs]


class AudioAsrCorrectionEvidence(EvidenceBase):
    kind: Literal["audio_asr_correction_evidence"] = "audio_asr_correction_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: AsrCorrectionPayload

    def outbound_object_refs(self) -> list[ObjectRef]:
        return [*super().outbound_object_refs(), *self.payload.applies_to]


class AudioDiarizationSegmentEvidence(EvidenceBase):
    kind: Literal["audio_diarization_segment_evidence"] = "audio_diarization_segment_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: DiarizationSegmentPayload


class AudioSpeakerIdentificationEvidence(EvidenceBase):
    kind: Literal["audio_speaker_identification_evidence"] = (
        "audio_speaker_identification_evidence"
    )
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: SpeakerIdentificationPayload


class AudioEmotionWindowEvidence(EvidenceBase):
    kind: Literal["audio_emotion_window_evidence"] = "audio_emotion_window_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: EmotionWindowPayload


class AudioEmotionSegmentEvidence(EvidenceBase):
    kind: Literal["audio_emotion_segment_evidence"] = "audio_emotion_segment_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: EmotionSegmentPayload


class AudioSoundEventSegmentEvidence(EvidenceBase):
    kind: Literal["audio_sound_event_segment_evidence"] = "audio_sound_event_segment_evidence"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: SoundEventSegmentPayload


# ============================================================
# Derived timeline products
# ============================================================


class AudioProfileSummary(StrictBaseModel):
    avg_rms_dbfs: float | None = None
    avg_estimated_snr_db: float | None = None
    avg_speech_ratio: UnitScore | None = None


class ContextSegmentPayload(StrictBaseModel):
    short_caption: str | None = None
    detailed_summary: str | None = None
    acoustic_scene_tags: list[TagScore] = Field(default_factory=list)
    sound_event_tags: list[TagScore] = Field(default_factory=list)
    speech_presence: SpeechPresence | None = None
    uncertainty_notes: list[str] = Field(default_factory=list)
    groundedness_score: UnitScore | None = None
    audio_profile: AudioProfileSummary = Field(default_factory=AudioProfileSummary)
    supporting_objects: list[ObjectRef] = Field(default_factory=list)


class ContextChangeMarkerPayload(StrictBaseModel):
    change_type: ChangeType
    description: str | None = None
    change_score: UnitScore | None = None
    signal_tags: list[TagScore] = Field(default_factory=list)
    left_object: ObjectRef | None = None
    right_object: ObjectRef | None = None


class QualityBinPayload(StrictBaseModel):
    metrics: dict[str, float] = Field(default_factory=dict)
    usability: dict[str, UnitScore] = Field(default_factory=dict)
    flags: list[ReasonCode] = Field(default_factory=list)

    @staticmethod
    def _is_extension_key(key: str) -> bool:
        return key.startswith(QUALITY_EXTENSION_PREFIXES)

    @model_validator(mode="after")
    def _validate_reserved_quality_keys(self) -> "QualityBinPayload":
        invalid_metric_keys = [
            key
            for key in self.metrics
            if key not in QUALITY_METRIC_KEYS and not self._is_extension_key(key)
        ]
        if invalid_metric_keys:
            raise ValueError(
                "Unsupported quality metric keys: "
                f"{invalid_metric_keys}. "
                "Use reserved keys or an extension prefix "
                f"{QUALITY_EXTENSION_PREFIXES}."
            )

        invalid_usability_keys = [
            key
            for key in self.usability
            if key not in QUALITY_USABILITY_KEYS and not self._is_extension_key(key)
        ]
        if invalid_usability_keys:
            raise ValueError(
                "Unsupported quality usability keys: "
                f"{invalid_usability_keys}. "
                "Use reserved keys or an extension prefix "
                f"{QUALITY_EXTENSION_PREFIXES}."
            )

        return self


class ContextSegment(DerivedBase):
    kind: Literal["context_segment"] = "context_segment"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: ContextSegmentPayload

    def outbound_object_refs(self) -> list[ObjectRef]:
        return [*super().outbound_object_refs(), *self.payload.supporting_objects]


class ContextChangeMarker(DerivedBase):
    kind: Literal["context_change_marker"] = "context_change_marker"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: ContextChangeMarkerPayload

    def outbound_object_refs(self) -> list[ObjectRef]:
        refs = [*super().outbound_object_refs()]
        if self.payload.left_object is not None:
            refs.append(self.payload.left_object)
        if self.payload.right_object is not None:
            refs.append(self.payload.right_object)
        return refs


class QualityBin(DerivedBase):
    kind: Literal["quality_bin"] = "quality_bin"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO
    payload: QualityBinPayload


# ============================================================
# Fused intervals
# ============================================================


class TranscriptSummary(StrictBaseModel):
    text: str | None = None
    corrected_text: str | None = None
    word_refs: list[ObjectRef] = Field(default_factory=list)
    language_code: str | None = None


class EmotionSummary(StrictBaseModel):
    label: str | None = None
    arousal_mean: float | None = None
    valence_mean: float | None = None
    dominance_mean: float | None = None


class SoundEventSummary(StrictBaseModel):
    dominant_sound_events: list[TagScore] = Field(default_factory=list)


class AudioQualitySummary(StrictBaseModel):
    avg_rms_dbfs: float | None = None
    avg_estimated_snr_db: float | None = None
    overlap_fraction: UnitScore | None = None
    low_confidence_fraction: UnitScore | None = None


class FusionNarrative(StrictBaseModel):
    summary: str | None = None
    uncertainty_notes: list[str] = Field(default_factory=list)
    review_worthy: bool = False
    annotation_worthy: bool = False


class FusedInterval(FusionBase):
    kind: Literal["fused_interval"] = "fused_interval"
    modality: Literal[Modality.AUDIO] = Modality.AUDIO

    fusion_kind: FusionKind

    speaker_label: str | None = None
    speaker_identity: str | None = None

    transcript: TranscriptSummary = Field(default_factory=TranscriptSummary)
    emotion: EmotionSummary = Field(default_factory=EmotionSummary)
    sound_events: SoundEventSummary = Field(default_factory=SoundEventSummary)

    context_segment: ObjectRef | None = None
    quality: AudioQualitySummary = Field(default_factory=AudioQualitySummary)
    narrative: FusionNarrative = Field(default_factory=FusionNarrative)

    def outbound_object_refs(self) -> list[ObjectRef]:
        refs = [*super().outbound_object_refs(), *self.transcript.word_refs]
        if self.context_segment is not None:
            refs.append(self.context_segment)
        return refs


# ============================================================
# Top-level unions
# ============================================================


TimelineObject = Annotated[
    AudioDspBinObservation
    | AudioContextWindowEvidence
    | AudioAsrWordEvidence
    | AudioAsrSegmentEvidence
    | AudioAsrCorrectionEvidence
    | AudioDiarizationSegmentEvidence
    | AudioSpeakerIdentificationEvidence
    | AudioEmotionWindowEvidence
    | AudioEmotionSegmentEvidence
    | AudioSoundEventSegmentEvidence
    | ContextSegment
    | ContextChangeMarker
    | QualityBin
    | FusedInterval,
    Field(discriminator="kind"),
]


# ============================================================
# Container
# ============================================================


class SessionBundle(StrictBaseModel):
    session: CaptureSession
    streams: list[SensorStream] = Field(default_factory=list)
    artifacts: list[Artifact] = Field(default_factory=list)
    objects: list[TimelineObject] = Field(default_factory=list)

    @model_validator(mode="after")
    def _validate_bundle(self) -> "SessionBundle":
        session_id = self.session.session_id

        stream_index: dict[str, SensorStream] = {}
        for stream in self.streams:
            if stream.session_id != session_id:
                raise ValueError(
                    f"stream {stream.stream_id} has session_id={stream.session_id}, "
                    f"expected {session_id}"
                )
            if stream.stream_id in stream_index:
                raise ValueError(f"duplicate stream_id: {stream.stream_id}")
            stream_index[stream.stream_id] = stream

        artifact_index: dict[str, Artifact] = {}
        for artifact in self.artifacts:
            if artifact.session_id != session_id:
                raise ValueError(
                    f"artifact {artifact.artifact_id} has session_id={artifact.session_id}, "
                    f"expected {session_id}"
                )
            if artifact.artifact_id in artifact_index:
                raise ValueError(f"duplicate artifact_id: {artifact.artifact_id}")
            for stream_ref in artifact.stream_refs:
                if stream_ref.stream_id not in stream_index:
                    raise ValueError(
                        f"artifact {artifact.artifact_id} references unknown stream_id "
                        f"{stream_ref.stream_id}"
                    )
            artifact_index[artifact.artifact_id] = artifact

        estimates: list[WallClockEstimate] = []
        if self.session.wall_clock_start is not None:
            estimates.append(self.session.wall_clock_start)
        estimates.extend(self.session.wall_clock_candidates)

        for estimate in estimates:
            for artifact_ref in estimate.supporting_artifact_refs:
                artifact = artifact_index.get(artifact_ref.artifact_id)
                if artifact is None:
                    raise ValueError(
                        "wall_clock estimate references unknown artifact_id "
                        f"{artifact_ref.artifact_id}"
                    )
                if (
                    artifact_ref.expected_role is not None
                    and artifact.artifact_role != artifact_ref.expected_role
                ):
                    raise ValueError(
                        "wall_clock estimate expected artifact "
                        f"{artifact_ref.artifact_id} to have role "
                        f"{artifact_ref.expected_role}, found {artifact.artifact_role}"
                    )

        # Validate any reference_stream_id on streams themselves.
        for stream in self.streams:
            ref_stream_id = stream.timebase.reference_stream_id
            if ref_stream_id is not None and ref_stream_id not in stream_index:
                raise ValueError(
                    f"stream {stream.stream_id} timebase references unknown stream_id "
                    f"{ref_stream_id}"
                )

        object_index: dict[str, TimelineObject] = {}
        for obj in self.objects:
            if obj.session_id != session_id:
                raise ValueError(
                    f"object {obj.object_id} has session_id={obj.session_id}, "
                    f"expected {session_id}"
                )
            if obj.object_id in object_index:
                raise ValueError(f"duplicate object_id: {obj.object_id}")
            object_index[obj.object_id] = obj

        for obj in self.objects:
            # Validate timebase reference_stream_id on temporal extents.
            ref_stream_id = obj.temporal.timebase.reference_stream_id
            if ref_stream_id is not None and ref_stream_id not in stream_index:
                raise ValueError(
                    f"object {obj.object_id} temporal timebase references unknown "
                    f"stream_id {ref_stream_id}"
                )

            for stream_ref in obj.outbound_stream_refs():
                if stream_ref.stream_id not in stream_index:
                    raise ValueError(
                        f"object {obj.object_id} references unknown stream_id "
                        f"{stream_ref.stream_id}"
                    )

            for artifact_ref in obj.outbound_artifact_refs():
                artifact = artifact_index.get(artifact_ref.artifact_id)
                if artifact is None:
                    raise ValueError(
                        f"object {obj.object_id} references unknown artifact_id "
                        f"{artifact_ref.artifact_id}"
                    )
                if (
                    artifact_ref.expected_role is not None
                    and artifact.artifact_role != artifact_ref.expected_role
                ):
                    raise ValueError(
                        f"object {obj.object_id} expected artifact "
                        f"{artifact_ref.artifact_id} to have role "
                        f"{artifact_ref.expected_role}, found {artifact.artifact_role}"
                    )

            for object_ref in obj.outbound_object_refs():
                target = object_index.get(object_ref.object_id)
                if target is None:
                    raise ValueError(
                        f"object {obj.object_id} references unknown object_id "
                        f"{object_ref.object_id}"
                    )
                if (
                    object_ref.expected_kind is not None
                    and target.kind != object_ref.expected_kind
                ):
                    raise ValueError(
                        f"object {obj.object_id} expected object "
                        f"{object_ref.object_id} to have kind "
                        f"{object_ref.expected_kind}, found {target.kind}"
                    )
                if (
                    object_ref.expected_family is not None
                    and target.family != object_ref.expected_family
                ):
                    raise ValueError(
                        f"object {obj.object_id} expected object "
                        f"{object_ref.object_id} to have family "
                        f"{object_ref.expected_family}, found {target.family}"
                    )

        return self

    def stream_index(self) -> dict[str, SensorStream]:
        return {stream.stream_id: stream for stream in self.streams}

    def artifact_index(self) -> dict[str, Artifact]:
        return {artifact.artifact_id: artifact for artifact in self.artifacts}

    def object_index(self) -> dict[str, TimelineObject]:
        return {obj.object_id: obj for obj in self.objects}

    def get_stream(self, stream_id: str) -> SensorStream | None:
        return self.stream_index().get(stream_id)

    def get_artifact(self, artifact_id: str) -> Artifact | None:
        return self.artifact_index().get(artifact_id)

    def get_object(self, object_id: str) -> TimelineObject | None:
        return self.object_index().get(object_id)

    def outbound_object_refs(self, object_id: str) -> list[ObjectRef]:
        obj = self.get_object(object_id)
        if obj is None:
            raise KeyError(f"unknown object_id: {object_id}")
        return obj.outbound_object_refs()

    def inbound_object_refs(self, object_id: str) -> list[tuple[str, ObjectRef]]:
        if self.get_object(object_id) is None:
            raise KeyError(f"unknown object_id: {object_id}")

        inbound: list[tuple[str, ObjectRef]] = []
        for obj in self.objects:
            for ref in obj.outbound_object_refs():
                if ref.object_id == object_id:
                    inbound.append((obj.object_id, ref))
        return inbound

    def validate_temporal_containment(self) -> list[str]:
        """
        Optional, non-core validation.
        Returns human-readable errors rather than raising by default.
        Only checks bounds when enough duration/span information is available.
        """
        errors: list[str] = []

        stream_index = self.stream_index()
        artifact_index = self.artifact_index()

        for obj in self.objects:
            if isinstance(obj.temporal, RelativeInstant):
                obj_start = obj.temporal.offset_s
                obj_end = obj.temporal.offset_s
            else:
                obj_start = obj.temporal.start_offset_s
                obj_end = obj.temporal.end_offset_s

            for stream_ref in obj.stream_refs:
                stream = stream_index.get(stream_ref.stream_id)
                if stream is None or stream.duration_s is None:
                    continue
                if obj_start < 0.0 or obj_end > stream.duration_s:
                    errors.append(
                        f"object {obj.object_id} exceeds stream {stream.stream_id} bounds"
                    )

            for artifact_ref in obj.outbound_artifact_refs():
                artifact = artifact_index.get(artifact_ref.artifact_id)
                if artifact is None:
                    continue
                if artifact.start_offset_s is None or artifact.end_offset_s is None:
                    continue
                if obj_start < artifact.start_offset_s or obj_end > artifact.end_offset_s:
                    errors.append(
                        f"object {obj.object_id} exceeds artifact {artifact.artifact_id} bounds"
                    )

        return errors
