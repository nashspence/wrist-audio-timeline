#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
HOST_DIR="${ROOT_DIR}"
if [[ -n "${LOCAL_WORKSPACE_FOLDER:-}" ]] \
  && [[ -d "${LOCAL_WORKSPACE_FOLDER}" ]] \
  && [[ -f "${LOCAL_WORKSPACE_FOLDER}/schema.py" ]] \
  && [[ -f "${LOCAL_WORKSPACE_FOLDER}/schema.sql" ]]; then
  HOST_DIR="${LOCAL_WORKSPACE_FOLDER}"
fi
PYTHON_IMAGE=python:3.12-slim
POSTGRES_IMAGE=postgres:16
POSTGRES_CONTAINER="wrist-audio-schema-test-postgres"

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  docker rm -f "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

expect_psql_failure() {
  local description="$1"
  local sql_file
  sql_file="$(mktemp)"
  cat >"${sql_file}"

  if docker exec -i "${POSTGRES_CONTAINER}" \
    psql -v ON_ERROR_STOP=1 -U postgres -d schema_test \
    <"${sql_file}" >/tmp/schema-test-failure.out 2>&1; then
    rm -f "${sql_file}"
    fail "expected SQL failure: ${description}"
  fi

  rm -f "${sql_file}"
}

trap cleanup EXIT

require_cmd docker
require_cmd python3
require_cmd psql

[[ -f "${ROOT_DIR}/schema.py" ]] || fail "schema.py not found in ${ROOT_DIR}"
[[ -f "${ROOT_DIR}/schema.sql" ]] || fail "schema.sql not found in ${ROOT_DIR}"
[[ -S /var/run/docker.sock ]] || fail "docker socket is not available"

log "Checking Docker outside of Docker workspace mapping"
docker run --rm \
  -v "${HOST_DIR}:/workspace:ro" \
  -w /workspace \
  alpine:3.22 \
  sh -lc 'test -f schema.py && test -f schema.sql'

log "Validating schema.py in a clean Python container"
docker run --rm \
  -v "${HOST_DIR}:/workspace:ro" \
  -w /workspace \
  "${PYTHON_IMAGE}" \
  sh -lc "
    set -e
    pip install --quiet --disable-pip-version-check 'pydantic>=2,<3'
    python - <<'PY'
import py_compile
py_compile.compile('schema.py', cfile='/tmp/schema.pyc', doraise=True)
print('py-compile-ok')
PY
    PYTHONPATH=/workspace python - <<'PY'
from datetime import datetime, timedelta, timezone

import schema


def expect_failure(fn, expected_substring):
    try:
        fn()
    except Exception as exc:
        message = str(exc)
        if expected_substring not in message:
            raise AssertionError(
                f\"expected failure containing {expected_substring!r}, got {message!r}\"
            ) from exc
    else:
        raise AssertionError(f\"expected failure containing {expected_substring!r}\")


span = schema.RelativeSpan(
    start_offset_s=10.0,
    end_offset_s=16.0,
    timebase=schema.TimebaseRef(
        clock_source=schema.ClockSource.DEVICE_MONOTONIC,
        reference_stream_id='mic-1',
    ),
)
assert span.duration_s == 6.0
assert span.center_offset_s == 13.0

session = schema.CaptureSession(
    session_id='session-1',
    duration_s=120.0,
    wall_clock_start=schema.WallClockEstimate(
        timestamp_utc=datetime(2026, 4, 13, 12, 0, tzinfo=timezone.utc),
        source=schema.WallClockEstimateSource.SERVER_INGEST,
        quality=schema.WallClockEstimateQuality.TRUSTED,
    ),
)

stream = schema.SensorStream(
    stream_id='mic-1',
    session_id='session-1',
    duration_s=120.0,
    nominal_sample_rate_hz=16000.0,
    timebase=schema.TimebaseRef(
        clock_source=schema.ClockSource.DEVICE_MONOTONIC,
        reference_stream_id='mic-1',
        alignment_uncertainty_ms=1.5,
    ),
    audio=schema.AudioProperties(sample_rate_hz=16000, channel_count=1),
)

artifact = schema.Artifact(
    artifact_id='artifact-1',
    session_id='session-1',
    artifact_role=schema.ArtifactRole.PRIMARY_MEDIA,
    uri='s3://bucket/audio.wav',
    artifact_format=schema.ArtifactFormat.WAV,
    start_offset_s=0.0,
    end_offset_s=120.0,
    stream_refs=[schema.ArtifactStreamRef(stream_id='mic-1', is_primary=True)],
    audio=schema.AudioProperties(sample_rate_hz=16000, channel_count=1),
)

context_window = schema.AudioContextWindowEvidence(
    object_id='ctxw-1',
    session_id='session-1',
    kind='audio_context_window_evidence',
    modality='audio',
    source_service='audio-understanding-service',
    confidence=schema.ConfidenceBundle(confidence_overall=0.8),
    temporal=schema.RelativeSpan(
        start_offset_s=0.0,
        end_offset_s=30.0,
        timebase=schema.TimebaseRef(
            clock_source=schema.ClockSource.DEVICE_MONOTONIC,
            reference_stream_id='mic-1',
        ),
    ),
    grid=schema.CONTEXT_30S_15S_GRID,
    payload=schema.AudioContextWindowPayload(
        short_caption='conversation indoors',
        acoustic_scene_tags=[schema.TagScore(tag='indoor', score=0.9)],
        sound_event_tags=[schema.TagScore(tag='speech', score=0.95)],
        speech_presence=schema.SpeechPresence.PRIMARY,
        groundedness_score=0.88,
    ),
    stream_refs=[schema.StreamRef(stream_id='mic-1')],
    artifact_refs=[
        schema.ArtifactRef(
            artifact_id='artifact-1',
            expected_role=schema.ArtifactRole.PRIMARY_MEDIA,
        )
    ],
)

context_segment = schema.ContextSegment(
    object_id='ctx-1',
    session_id='session-1',
    kind='context_segment',
    modality='audio',
    confidence=schema.ConfidenceBundle(confidence_overall=0.85),
    temporal=schema.RelativeSpan(
        start_offset_s=0.0,
        end_offset_s=30.0,
        timebase=schema.TimebaseRef(
            clock_source=schema.ClockSource.DEVICE_MONOTONIC,
            reference_stream_id='mic-1',
        ),
    ),
    payload=schema.ContextSegmentPayload(
        short_caption='meeting audio',
        detailed_summary='One speaker talking in a quiet office.',
        acoustic_scene_tags=[schema.TagScore(tag='office', score=0.84)],
        sound_event_tags=[schema.TagScore(tag='speech', score=0.96)],
        speech_presence=schema.SpeechPresence.PRIMARY,
        uncertainty_notes=['limited background context'],
        groundedness_score=0.82,
        audio_profile=schema.AudioProfileSummary(
            avg_rms_dbfs=-24.0,
            avg_estimated_snr_db=18.5,
            avg_speech_ratio=0.71,
        ),
        supporting_objects=[
            schema.ObjectRef(
                object_id='ctxw-1',
                expected_family=schema.TimelineObjectFamily.EVIDENCE,
            )
        ],
    ),
    derived_from=[
        schema.ObjectRef(
            object_id='ctxw-1',
            expected_kind='audio_context_window_evidence',
        )
    ],
    stream_refs=[schema.StreamRef(stream_id='mic-1')],
)

quality_bin = schema.QualityBin(
    object_id='q-1',
    session_id='session-1',
    kind='quality_bin',
    modality='audio',
    confidence=schema.ConfidenceBundle(confidence_overall=0.9),
    temporal=schema.RelativeSpan(
        start_offset_s=0.0,
        end_offset_s=0.5,
        timebase=schema.TimebaseRef(
            clock_source=schema.ClockSource.DEVICE_MONOTONIC,
            reference_stream_id='mic-1',
        ),
    ),
    grid=schema.BASE_500MS_GRID,
    payload=schema.QualityBinPayload(
        metrics={
            'rms_dbfs': -23.5,
            'estimated_snr_db': 17.2,
            'speech_ratio': 0.7,
        },
        usability={'asr': 0.8, 'overall': 0.83},
    ),
    derived_from=[schema.ObjectRef(object_id='ctxw-1')],
    stream_refs=[schema.StreamRef(stream_id='mic-1')],
)

fused = schema.FusedInterval(
    object_id='fusion-1',
    session_id='session-1',
    kind='fused_interval',
    modality='audio',
    fusion_kind=schema.FusionKind.CONVERSATION_INTERVAL,
    confidence=schema.ConfidenceBundle(confidence_overall=0.87),
    temporal=schema.RelativeSpan(
        start_offset_s=0.0,
        end_offset_s=30.0,
        timebase=schema.TimebaseRef(
            clock_source=schema.ClockSource.DEVICE_MONOTONIC,
            reference_stream_id='mic-1',
        ),
    ),
    transcript=schema.TranscriptSummary(text='hello there', corrected_text='hello there'),
    context_segment=schema.ObjectRef(object_id='ctx-1', expected_kind='context_segment'),
    quality=schema.AudioQualitySummary(
        avg_rms_dbfs=-24.0,
        avg_estimated_snr_db=18.5,
    ),
    narrative=schema.FusionNarrative(summary='A short conversational interval.'),
    fused_from=[
        schema.ObjectRef(
            object_id='ctx-1',
            expected_family=schema.TimelineObjectFamily.DERIVED,
        )
    ],
    stream_refs=[schema.StreamRef(stream_id='mic-1')],
)

bundle = schema.SessionBundle(
    session=session,
    streams=[stream],
    artifacts=[artifact],
    objects=[context_window, context_segment, quality_bin, fused],
)

assert bundle.validate_temporal_containment() == []
assert bundle.get_artifact('artifact-1').artifact_format == schema.ArtifactFormat.WAV
assert bundle.get_object('ctx-1').kind == 'context_segment'

expect_failure(
    lambda: schema.RelativeSpan(
        start_offset_s=1.0,
        end_offset_s=1.0,
        timebase=schema.TimebaseRef(
            clock_source=schema.ClockSource.DEVICE_MONOTONIC,
            reference_stream_id='mic-1',
        ),
    ),
    'end_offset_s must be greater than start_offset_s',
)
expect_failure(
    lambda: schema.WallClockEstimate(
        timestamp_utc=datetime(2026, 4, 13, 12, 0),
        source=schema.WallClockEstimateSource.SERVER_INGEST,
        quality=schema.WallClockEstimateQuality.TRUSTED,
    ),
    'timezone-aware',
)
expect_failure(
    lambda: schema.WallClockEstimate(
        timestamp_utc=datetime(
            2026,
            4,
            13,
            13,
            0,
            tzinfo=timezone(timedelta(hours=1)),
        ),
        source=schema.WallClockEstimateSource.SERVER_INGEST,
        quality=schema.WallClockEstimateQuality.TRUSTED,
    ),
    'normalized to UTC',
)
expect_failure(
    lambda: schema.QualityBinPayload(metrics={'unexpected_metric': 1.0}),
    'Unsupported quality metric keys',
)
expect_failure(
    lambda: schema.Artifact(
        artifact_id='artifact-dup',
        session_id='session-1',
        artifact_role=schema.ArtifactRole.PRIMARY_MEDIA,
        uri='s3://bucket/audio.wav',
        stream_refs=[
            schema.ArtifactStreamRef(stream_id='mic-1', is_primary=True),
            schema.ArtifactStreamRef(stream_id='mic-1'),
        ],
    ),
    'must not repeat the same stream_id',
)
expect_failure(
    lambda: schema.Artifact(
        artifact_id='artifact-many-primary',
        session_id='session-1',
        artifact_role=schema.ArtifactRole.PRIMARY_MEDIA,
        uri='s3://bucket/audio.wav',
        stream_refs=[
            schema.ArtifactStreamRef(stream_id='mic-1', is_primary=True),
            schema.ArtifactStreamRef(stream_id='mic-2', is_primary=True),
        ],
    ),
    'may mark at most one primary stream',
)
expect_failure(
    lambda: schema.SessionBundle(
        session=session,
        streams=[stream],
        artifacts=[artifact],
        objects=[
            schema.ContextSegment(
                object_id='bad-ctx',
                session_id='session-1',
                kind='context_segment',
                modality='audio',
                confidence=schema.ConfidenceBundle(confidence_overall=0.5),
                temporal=schema.RelativeSpan(
                    start_offset_s=0.0,
                    end_offset_s=10.0,
                    timebase=schema.TimebaseRef(
                        clock_source=schema.ClockSource.DEVICE_MONOTONIC,
                        reference_stream_id='missing-stream',
                    ),
                ),
                payload=schema.ContextSegmentPayload(),
            )
        ],
    ),
    'references unknown stream_id',
)

print('python-schema-tests-ok')
PY
  "

log "Starting PostgreSQL schema validation container"
cleanup
docker run -d \
  --name "${POSTGRES_CONTAINER}" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=schema_test \
  -v "${HOST_DIR}:/workspace:ro" \
  "${POSTGRES_IMAGE}" >/dev/null

for _ in $(seq 1 30); do
  if docker exec "${POSTGRES_CONTAINER}" pg_isready -U postgres -d schema_test >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "${POSTGRES_CONTAINER}" \
  psql -v ON_ERROR_STOP=1 -U postgres -d schema_test -f /workspace/schema.sql >/dev/null

docker exec "${POSTGRES_CONTAINER}" \
  psql -v ON_ERROR_STOP=1 -U postgres -d schema_test -f /workspace/schema.sql >/dev/null

log "Running PostgreSQL positive-path validation"
docker exec -i "${POSTGRES_CONTAINER}" \
  psql -v ON_ERROR_STOP=1 -U postgres -d schema_test >/dev/null <<'SQL'
begin;

insert into wrist_audio.capture_session (session_id, duration_s)
values ('session-1', 120.0);

insert into wrist_audio.sensor_stream (
  session_id,
  stream_id,
  stream_kind_code,
  duration_s,
  timebase_clock_source,
  timebase_reference_stream_id
) values (
  'session-1',
  'mic-1',
  'microphone',
  120.0,
  'device_monotonic',
  'mic-1'
);

insert into wrist_audio.audio_stream (
  session_id,
  stream_id,
  sample_rate_hz,
  channel_count,
  nominal_sample_rate_hz
) values (
  'session-1',
  'mic-1',
  16000,
  1,
  16000.0
);

insert into wrist_audio.artifact (
  session_id,
  artifact_id,
  modality_code,
  artifact_role_code,
  uri,
  format_code,
  start_offset_s,
  end_offset_s
) values (
  'session-1',
  'artifact-1',
  'audio',
  'primary_media',
  's3://bucket/audio.wav',
  'wav',
  0.0,
  120.0
);

insert into wrist_audio.artifact_stream_ref (
  session_id,
  artifact_id,
  ref_ordinal,
  stream_id,
  is_primary
) values (
  'session-1',
  'artifact-1',
  0,
  'mic-1',
  true
);

insert into wrist_audio.timeline_object (
  session_id,
  object_id,
  kind_code,
  source_service,
  confidence_overall,
  time_kind,
  start_offset_s,
  end_offset_s,
  timebase_clock_source,
  timebase_reference_stream_id
) values
  (
    'session-1',
    'ctx-1',
    'context_segment',
    'timeline_derivation_service',
    0.90,
    'relative_span',
    0.0,
    30.0,
    'device_monotonic',
    'mic-1'
  ),
  (
    'session-1',
    'q-1',
    'quality_bin',
    'timeline_derivation_service',
    0.88,
    'relative_span',
    0.0,
    0.5,
    'device_monotonic',
    'mic-1'
  );

insert into wrist_audio.context_segment (
  session_id,
  object_id,
  short_caption,
  detailed_summary,
  speech_presence_code,
  groundedness_score,
  avg_rms_dbfs,
  avg_estimated_snr_db,
  avg_speech_ratio
) values (
  'session-1',
  'ctx-1',
  'meeting audio',
  'One speaker in a quiet office.',
  'primary',
  0.82,
  -24.0,
  18.5,
  0.71
);

insert into wrist_audio.quality_bin (
  session_id,
  object_id
) values (
  'session-1',
  'q-1'
);

insert into wrist_audio.object_artifact_ref (
  session_id,
  src_object_id,
  ref_ordinal,
  dst_artifact_id,
  expected_artifact_role_code
) values (
  'session-1',
  'ctx-1',
  0,
  'artifact-1',
  'primary_media'
);

insert into wrist_audio.object_ref (
  session_id,
  src_object_id,
  ref_ordinal,
  dst_object_id,
  expected_kind_code,
  expected_family
) values (
  'session-1',
  'ctx-1',
  0,
  'q-1',
  'quality_bin',
  'derived'
);

insert into wrist_audio.session_wall_clock_candidate (
  session_id,
  candidate_ordinal,
  timestamp_utc,
  source,
  quality,
  is_primary
) values (
  'session-1',
  0,
  '2026-04-13 12:00:00+00',
  'server_ingest',
  'trusted',
  true
);

commit;
SQL

tables_count="$(docker exec "${POSTGRES_CONTAINER}" psql -At -U postgres -d schema_test -c \
  "select count(*) from information_schema.tables where table_schema = 'wrist_audio';")"
object_kind_count="$(docker exec "${POSTGRES_CONTAINER}" psql -At -U postgres -d schema_test -c \
  "select count(*) from wrist_audio.object_kind;")"
grid_count="$(docker exec "${POSTGRES_CONTAINER}" psql -At -U postgres -d schema_test -c \
  "select count(*) from wrist_audio.grid_definition;")"
context_segment_count="$(docker exec "${POSTGRES_CONTAINER}" psql -At -U postgres -d schema_test -c \
  "select count(*) from wrist_audio.context_segment;")"
object_ref_count="$(docker exec "${POSTGRES_CONTAINER}" psql -At -U postgres -d schema_test -c \
  "select count(*) from wrist_audio.object_ref;")"

assert_eq "${object_kind_count}" "14" "unexpected object_kind seed count"
assert_eq "${grid_count}" "2" "unexpected grid_definition seed count"
assert_eq "${context_segment_count}" "1" "expected one persisted context_segment"
assert_eq "${object_ref_count}" "1" "expected one persisted object_ref"

if [[ "${tables_count}" -lt 40 ]]; then
  fail "expected at least 40 tables in wrist_audio schema, got ${tables_count}"
fi

log "Running PostgreSQL negative-path validation"
expect_psql_failure "sensor_stream without subtype row should fail" <<'SQL'
begin;
insert into wrist_audio.capture_session (session_id, duration_s)
values ('session-2', 60.0);
insert into wrist_audio.sensor_stream (
  session_id,
  stream_id,
  stream_kind_code,
  duration_s,
  timebase_clock_source,
  timebase_reference_stream_id
) values (
  'session-2',
  'mic-2',
  'microphone',
  60.0,
  'device_monotonic',
  'mic-2'
);
commit;
SQL

expect_psql_failure "context_segment payload table must match object kind" <<'SQL'
begin;
insert into wrist_audio.timeline_object (
  session_id,
  object_id,
  kind_code,
  source_service,
  confidence_overall,
  time_kind,
  start_offset_s,
  end_offset_s,
  timebase_clock_source,
  timebase_reference_stream_id
) values (
  'session-1',
  'bad-kind',
  'quality_bin',
  'timeline_derivation_service',
  0.5,
  'relative_span',
  0.0,
  1.0,
  'device_monotonic',
  'mic-1'
);
insert into wrist_audio.context_segment (
  session_id,
  object_id
) values (
  'session-1',
  'bad-kind'
);
rollback;
SQL

expect_psql_failure "object_ref expected kind must be enforced" <<'SQL'
begin;
insert into wrist_audio.object_ref (
  session_id,
  src_object_id,
  ref_ordinal,
  dst_object_id,
  expected_kind_code,
  expected_family
) values (
  'session-1',
  'ctx-1',
  99,
  'q-1',
  'fused_interval',
  'derived'
);
rollback;
SQL

expect_psql_failure "only one primary wall-clock candidate is allowed per session" <<'SQL'
begin;
insert into wrist_audio.session_wall_clock_candidate (
  session_id,
  candidate_ordinal,
  timestamp_utc,
  source,
  quality,
  is_primary
) values (
  'session-1',
  1,
  '2026-04-13 12:00:05+00',
  'server_ingest',
  'trusted',
  true
);
commit;
SQL

log "All schema tests passed"
