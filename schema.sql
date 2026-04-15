-- Normalized PostgreSQL persistence schema for the wrist-audio timeline model.
-- Canonical semantics are defined in SCHEMA.md and expressed in the exchange model in schema.py.
--
-- Design goals:
-- 1) Keep the runtime scope audio-focused now, while leaving the relational core easy to extend.
-- 2) Store evolving vocabularies in lookup catalogs instead of hard-coded enums/checks.
-- 3) Preserve typed refs, lineage, and durable payloads needed for downstream retrieval.
-- 4) Separate generic supertypes from audio-specific subtype tables.
-- 5) Keep the canonical exchange schema and the persistence schema aligned in semantics,
--    even when nested collections are decomposed into normalized child tables.

create schema if not exists wrist_audio;
set search_path = wrist_audio, public;

-- ============================================================
-- Stable domains and enums
-- ============================================================

do $$
begin
    if to_regtype('wrist_audio.nonnegative_double') is null then
        execute 'create domain wrist_audio.nonnegative_double as double precision check (value >= 0.0)';
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.positive_double') is null then
        execute 'create domain wrist_audio.positive_double as double precision check (value > 0.0)';
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.unit_score') is null then
        execute 'create domain wrist_audio.unit_score as double precision check (value >= 0.0 and value <= 1.0)';
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.severity') is null then
        execute $enum$
            create type wrist_audio.severity as enum (
                'info',
                'warning',
                'error'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.timeline_object_family') is null then
        execute $enum$
            create type wrist_audio.timeline_object_family as enum (
                'observation',
                'evidence',
                'derived',
                'fusion'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.time_kind') is null then
        execute $enum$
            create type wrist_audio.time_kind as enum (
                'relative_instant',
                'relative_span'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.grid_kind') is null then
        execute $enum$
            create type wrist_audio.grid_kind as enum (
                'regular_bins',
                'sliding_windows',
                'other'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.clock_source') is null then
        execute $enum$
            create type wrist_audio.clock_source as enum (
                'device_monotonic',
                'server_ingest',
                'manual',
                'derived'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.wall_clock_estimate_source') is null then
        execute $enum$
            create type wrist_audio.wall_clock_estimate_source as enum (
                'device_file_mtime',
                'device_metadata',
                'user_declared',
                'server_ingest',
                'derived'
            )
        $enum$;
    end if;
end
$$;

do $$
begin
    if to_regtype('wrist_audio.wall_clock_estimate_quality') is null then
        execute $enum$
            create type wrist_audio.wall_clock_estimate_quality as enum (
                'trusted',
                'approximate',
                'weak',
                'guessed'
            )
        $enum$;
    end if;
end
$$;

-- ============================================================
-- Vocabulary catalogs
-- ============================================================

create table if not exists modality (
    modality_code text primary key,
    description text not null
);

create table if not exists stream_kind (
    stream_kind_code text primary key,
    modality_code text not null,
    description text not null,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict
);

create table if not exists artifact_role (
    artifact_role_code text primary key,
    description text not null
);

create table if not exists artifact_format (
    format_code text primary key,
    description text not null,
    preferred_mime_type text
);

create table if not exists speech_presence (
    speech_presence_code text primary key,
    description text not null
);

create table if not exists correction_type (
    correction_type_code text primary key,
    description text not null
);

create table if not exists change_type (
    change_type_code text primary key,
    description text not null
);

create table if not exists fusion_kind (
    fusion_kind_code text primary key,
    description text not null
);

create table if not exists tag_domain (
    tag_domain_code text primary key,
    description text not null
);

create table if not exists quality_metric_definition (
    metric_code text primary key,
    description text not null,
    modality_code text,
    is_reserved boolean not null default false,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict
);

create table if not exists quality_usability_definition (
    usability_code text primary key,
    description text not null,
    modality_code text,
    is_reserved boolean not null default false,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict
);

create table if not exists object_kind (
    kind_code text primary key,
    family timeline_object_family not null,
    modality_code text not null,
    is_durable boolean not null default false,
    payload_table_name text,
    description text not null,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict
);

create table if not exists grid_definition (
    grid_id text primary key,
    modality_code text not null,
    grid_kind grid_kind not null,
    origin_offset_s nonnegative_double not null default 0.0,
    bin_size_s positive_double,
    window_size_s positive_double,
    hop_size_s positive_double,
    description text,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict,
    check (
        (grid_kind = 'regular_bins' and bin_size_s is not null and window_size_s is null and hop_size_s is null)
        or
        (grid_kind = 'sliding_windows' and bin_size_s is null and window_size_s is not null and hop_size_s is not null)
        or
        (grid_kind = 'other')
    )
);

-- ============================================================
-- Root records
-- ============================================================

create table if not exists capture_session (
    session_id text primary key,
    schema_version text not null default 'v1.0.0-alpha.2',
    duration_s positive_double,
    wearer_id text,
    session_timezone text,
    notes text,
    created_at timestamptz not null default now()
);

create table if not exists capture_session_property (
    session_id text not null,
    property_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, property_key, value_ordinal),
    foreign key (session_id)
        references capture_session (session_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

create table if not exists session_wall_clock_candidate (
    session_id text not null,
    candidate_ordinal integer not null,
    timestamp_utc timestamptz not null,
    source wall_clock_estimate_source not null,
    quality wall_clock_estimate_quality not null,
    is_primary boolean not null default false,
    uncertainty_before_s nonnegative_double not null default 0.0,
    uncertainty_after_s nonnegative_double not null default 0.0,
    rationale text,
    primary key (session_id, candidate_ordinal),
    foreign key (session_id)
        references capture_session (session_id)
        on delete cascade,
    check (candidate_ordinal >= 0)
);

create table if not exists session_wall_clock_candidate_artifact_ref (
    session_id text not null,
    candidate_ordinal integer not null,
    ref_ordinal integer not null,
    artifact_id text not null,
    relation text,
    expected_artifact_role_code text,
    primary key (session_id, candidate_ordinal, ref_ordinal),
    foreign key (session_id, candidate_ordinal)
        references session_wall_clock_candidate (session_id, candidate_ordinal)
        on delete cascade,
    check (ref_ordinal >= 0)
);

create table if not exists sensor_stream (
    session_id text not null,
    stream_id text not null,
    schema_version text not null default 'v1.0.0-alpha.2',
    stream_kind_code text not null,
    name text,
    duration_s positive_double,
    timebase_clock_source clock_source not null,
    timebase_reference_stream_id text,
    alignment_uncertainty_ms nonnegative_double,
    source text,
    device_id text,
    mount_position text,
    notes text,
    created_at timestamptz not null default now(),
    primary key (session_id, stream_id),
    foreign key (session_id)
        references capture_session (session_id)
        on delete cascade,
    foreign key (stream_kind_code)
        references stream_kind (stream_kind_code)
        on delete restrict,
    foreign key (session_id, timebase_reference_stream_id)
        references sensor_stream (session_id, stream_id)
        deferrable initially deferred
);

create table if not exists sensor_stream_property (
    session_id text not null,
    stream_id text not null,
    property_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, stream_id, property_key, value_ordinal),
    foreign key (session_id, stream_id)
        references sensor_stream (session_id, stream_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

-- Audio subtype table. Future modalities can add sibling subtype tables in later migrations.
create table if not exists audio_stream (
    session_id text not null,
    stream_id text not null,
    sample_rate_hz integer not null,
    channel_count integer not null,
    nominal_sample_rate_hz positive_double,
    primary key (session_id, stream_id),
    foreign key (session_id, stream_id)
        references sensor_stream (session_id, stream_id)
        on delete cascade,
    check (sample_rate_hz > 0),
    check (channel_count > 0)
);

create table if not exists artifact (
    session_id text not null,
    artifact_id text not null,
    schema_version text not null default 'v1.0.0-alpha.2',
    modality_code text not null,
    artifact_role_code text not null,
    uri text not null,
    sha256 text,
    mime_type text,
    format_code text,
    byte_size bigint,
    start_offset_s nonnegative_double,
    end_offset_s nonnegative_double,
    relative_time numrange generated always as (
        case
            when start_offset_s is null or end_offset_s is null then null
            else numrange(start_offset_s::numeric, end_offset_s::numeric, '[)')
        end
    ) stored,
    created_at timestamptz not null default now(),
    primary key (session_id, artifact_id),
    foreign key (session_id)
        references capture_session (session_id)
        on delete cascade,
    foreign key (modality_code)
        references modality (modality_code)
        on delete restrict,
    foreign key (artifact_role_code)
        references artifact_role (artifact_role_code)
        on delete restrict,
    foreign key (format_code)
        references artifact_format (format_code)
        on delete restrict,
    check (byte_size is null or byte_size >= 0),
    check (
        (start_offset_s is null and end_offset_s is null)
        or
        (start_offset_s is not null and end_offset_s is not null and end_offset_s > start_offset_s)
    )
);

create table if not exists artifact_property (
    session_id text not null,
    artifact_id text not null,
    property_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, artifact_id, property_key, value_ordinal),
    foreign key (session_id, artifact_id)
        references artifact (session_id, artifact_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

create table if not exists artifact_stream_ref (
    session_id text not null,
    artifact_id text not null,
    ref_ordinal integer not null,
    stream_id text not null,
    relation text,
    is_primary boolean not null default false,
    primary key (session_id, artifact_id, ref_ordinal),
    foreign key (session_id, artifact_id)
        references artifact (session_id, artifact_id)
        on delete cascade,
    foreign key (session_id, stream_id)
        references sensor_stream (session_id, stream_id)
        on delete cascade,
    check (ref_ordinal >= 0)
);

create unique index if not exists artifact_stream_ref_one_primary
    on artifact_stream_ref (session_id, artifact_id)
    where is_primary;

-- Audio artifact profile table. Future modalities can add sibling profile tables in later migrations.
create table if not exists audio_artifact_profile (
    session_id text not null,
    artifact_id text not null,
    sample_rate_hz integer,
    channel_count integer,
    duration_frames bigint,
    primary key (session_id, artifact_id),
    foreign key (session_id, artifact_id)
        references artifact (session_id, artifact_id)
        on delete cascade,
    check (sample_rate_hz is null or sample_rate_hz > 0),
    check (channel_count is null or channel_count > 0),
    check (duration_frames is null or duration_frames >= 0)
);

-- ============================================================
-- Timeline object core
-- ============================================================

create table if not exists timeline_object (
    session_id text not null,
    object_id text not null,
    schema_version text not null default 'v1.0.0-alpha.2',
    kind_code text not null,
    source_service text not null,
    source_model text,
    confidence_overall unit_score not null,
    time_kind time_kind not null,
    start_offset_s nonnegative_double not null,
    end_offset_s nonnegative_double not null,
    grid_id text,
    timebase_clock_source clock_source not null,
    timebase_reference_stream_id text,
    timebase_alignment_uncertainty_ms nonnegative_double,
    timebase_sync_notes text,
    relative_time numrange generated always as (
        case
            when time_kind = 'relative_instant' then numrange(start_offset_s::numeric, start_offset_s::numeric, '[]')
            else numrange(start_offset_s::numeric, end_offset_s::numeric, '[)')
        end
    ) stored,
    created_at timestamptz not null default now(),
    primary key (session_id, object_id),
    foreign key (session_id)
        references capture_session (session_id)
        on delete cascade,
    foreign key (kind_code)
        references object_kind (kind_code)
        on delete restrict,
    foreign key (grid_id)
        references grid_definition (grid_id)
        on delete restrict,
    foreign key (session_id, timebase_reference_stream_id)
        references sensor_stream (session_id, stream_id)
        deferrable initially deferred,
    check (
        (time_kind = 'relative_instant' and end_offset_s = start_offset_s)
        or
        (time_kind = 'relative_span' and end_offset_s > start_offset_s)
    )
);

create table if not exists timeline_object_attribute (
    session_id text not null,
    object_id text not null,
    attribute_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, object_id, attribute_key, value_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

create table if not exists timeline_object_native_output (
    session_id text not null,
    object_id text not null,
    output_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, object_id, output_key, value_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

create table if not exists timeline_object_service_metadata (
    session_id text not null,
    object_id text not null,
    metadata_key text not null,
    value_ordinal integer not null default 0,
    value_text text,
    value_number double precision,
    value_boolean boolean,
    value_timestamp timestamptz,
    primary key (session_id, object_id, metadata_key, value_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (value_ordinal >= 0),
    check (num_nonnulls(value_text, value_number, value_boolean, value_timestamp) = 1)
);

create table if not exists timeline_object_confidence_subscore (
    session_id text not null,
    object_id text not null,
    subscore_code text not null,
    score unit_score not null,
    primary key (session_id, object_id, subscore_code),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade
);

create table if not exists timeline_object_confidence_basis (
    session_id text not null,
    object_id text not null,
    basis_ordinal integer not null,
    basis_text text not null,
    primary key (session_id, object_id, basis_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (basis_ordinal >= 0)
);

create table if not exists timeline_object_reason (
    session_id text not null,
    object_id text not null,
    reason_scope text not null default 'confidence',
    reason_ordinal integer not null,
    code text not null,
    severity severity not null,
    message text not null,
    primary key (session_id, object_id, reason_scope, reason_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (reason_ordinal >= 0)
);

create table if not exists timeline_object_provenance (
    session_id text not null,
    object_id text not null,
    provenance_ordinal integer not null,
    source_service text not null,
    source_object_id text not null,
    source_kind_code text,
    weight unit_score,
    primary key (session_id, object_id, provenance_ordinal),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    check (provenance_ordinal >= 0),
    foreign key (source_kind_code)
        references object_kind (kind_code)
        on delete restrict
);

create table if not exists object_stream_ref (
    session_id text not null,
    src_object_id text not null,
    ref_ordinal integer not null,
    dst_stream_id text not null,
    relation text,
    primary key (session_id, src_object_id, ref_ordinal),
    foreign key (session_id, src_object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (session_id, dst_stream_id)
        references sensor_stream (session_id, stream_id)
        on delete cascade,
    check (ref_ordinal >= 0)
);

create table if not exists object_artifact_ref (
    session_id text not null,
    src_object_id text not null,
    ref_ordinal integer not null,
    dst_artifact_id text not null,
    relation text,
    expected_artifact_role_code text,
    primary key (session_id, src_object_id, ref_ordinal),
    foreign key (session_id, src_object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (session_id, dst_artifact_id)
        references artifact (session_id, artifact_id)
        on delete cascade,
    foreign key (expected_artifact_role_code)
        references artifact_role (artifact_role_code)
        on delete restrict,
    check (ref_ordinal >= 0)
);

create table if not exists object_ref (
    session_id text not null,
    src_object_id text not null,
    ref_ordinal integer not null,
    dst_object_id text not null,
    relation text,
    expected_kind_code text,
    expected_family timeline_object_family,
    primary key (session_id, src_object_id, ref_ordinal),
    foreign key (session_id, src_object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (session_id, dst_object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (expected_kind_code)
        references object_kind (kind_code)
        on delete restrict,
    check (ref_ordinal >= 0)
);

-- ============================================================
-- Durable payload tables for current wrist-audio phase
-- ============================================================

create table if not exists context_segment (
    session_id text not null,
    object_id text not null,
    short_caption text,
    detailed_summary text,
    speech_presence_code text,
    groundedness_score unit_score,
    avg_rms_dbfs double precision,
    avg_estimated_snr_db double precision,
    avg_speech_ratio unit_score,
    primary key (session_id, object_id),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (speech_presence_code)
        references speech_presence (speech_presence_code)
        on delete restrict
);

create table if not exists context_segment_note (
    session_id text not null,
    object_id text not null,
    note_ordinal integer not null,
    note_text text not null,
    primary key (session_id, object_id, note_ordinal),
    foreign key (session_id, object_id)
        references context_segment (session_id, object_id)
        on delete cascade,
    check (note_ordinal >= 0)
);

create table if not exists context_segment_tag (
    session_id text not null,
    object_id text not null,
    tag_domain_code text not null,
    tag_ordinal integer not null,
    tag_label text not null,
    score unit_score not null,
    primary key (session_id, object_id, tag_domain_code, tag_ordinal),
    foreign key (session_id, object_id)
        references context_segment (session_id, object_id)
        on delete cascade,
    foreign key (tag_domain_code)
        references tag_domain (tag_domain_code)
        on delete restrict,
    check (tag_ordinal >= 0)
);

create table if not exists context_change_marker (
    session_id text not null,
    object_id text not null,
    change_type_code text not null,
    description text,
    change_score unit_score,
    primary key (session_id, object_id),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (change_type_code)
        references change_type (change_type_code)
        on delete restrict
);

create table if not exists context_change_marker_tag (
    session_id text not null,
    object_id text not null,
    tag_domain_code text not null,
    tag_ordinal integer not null,
    tag_label text not null,
    score unit_score not null,
    primary key (session_id, object_id, tag_domain_code, tag_ordinal),
    foreign key (session_id, object_id)
        references context_change_marker (session_id, object_id)
        on delete cascade,
    foreign key (tag_domain_code)
        references tag_domain (tag_domain_code)
        on delete restrict,
    check (tag_ordinal >= 0)
);

create table if not exists quality_bin (
    session_id text not null,
    object_id text not null,
    primary key (session_id, object_id),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade
);

create table if not exists quality_bin_metric (
    session_id text not null,
    object_id text not null,
    metric_code text not null,
    metric_value double precision not null,
    primary key (session_id, object_id, metric_code),
    foreign key (session_id, object_id)
        references quality_bin (session_id, object_id)
        on delete cascade,
    foreign key (metric_code)
        references quality_metric_definition (metric_code)
        on delete restrict
);

create table if not exists quality_bin_usability (
    session_id text not null,
    object_id text not null,
    usability_code text not null,
    score unit_score not null,
    primary key (session_id, object_id, usability_code),
    foreign key (session_id, object_id)
        references quality_bin (session_id, object_id)
        on delete cascade,
    foreign key (usability_code)
        references quality_usability_definition (usability_code)
        on delete restrict
);

create table if not exists quality_bin_flag (
    session_id text not null,
    object_id text not null,
    flag_ordinal integer not null,
    code text not null,
    severity severity not null,
    message text not null,
    primary key (session_id, object_id, flag_ordinal),
    foreign key (session_id, object_id)
        references quality_bin (session_id, object_id)
        on delete cascade,
    check (flag_ordinal >= 0)
);

create table if not exists fused_interval (
    session_id text not null,
    object_id text not null,
    fusion_kind_code text not null,
    speaker_label text,
    speaker_identity text,
    transcript_text text,
    transcript_corrected_text text,
    transcript_language_code text,
    emotion_label text,
    emotion_arousal_mean double precision,
    emotion_valence_mean double precision,
    emotion_dominance_mean double precision,
    media_present boolean,
    media_kind text,
    media_title text,
    media_primary_attribution text,
    media_identification_confidence unit_score,
    quality_avg_rms_dbfs double precision,
    quality_avg_estimated_snr_db double precision,
    quality_overlap_fraction unit_score,
    quality_low_confidence_fraction unit_score,
    narrative_summary text,
    review_worthy boolean not null default false,
    annotation_worthy boolean not null default false,
    search_vector tsvector generated always as (
        setweight(to_tsvector('simple', coalesce(transcript_corrected_text, transcript_text, '')), 'A')
        || setweight(to_tsvector('simple', coalesce(narrative_summary, '')), 'B')
        || setweight(to_tsvector('simple', coalesce(speaker_identity, speaker_label, '')), 'C')
        || setweight(to_tsvector('simple', coalesce(media_title, '')), 'C')
        || setweight(to_tsvector('simple', coalesce(media_primary_attribution, '')), 'C')
        || setweight(to_tsvector('simple', coalesce(media_kind, '')), 'D')
    ) stored,
    primary key (session_id, object_id),
    foreign key (session_id, object_id)
        references timeline_object (session_id, object_id)
        on delete cascade,
    foreign key (fusion_kind_code)
        references fusion_kind (fusion_kind_code)
        on delete restrict
);

create table if not exists fused_interval_tag (
    session_id text not null,
    object_id text not null,
    tag_domain_code text not null,
    tag_ordinal integer not null,
    tag_label text not null,
    score unit_score not null,
    primary key (session_id, object_id, tag_domain_code, tag_ordinal),
    foreign key (session_id, object_id)
        references fused_interval (session_id, object_id)
        on delete cascade,
    foreign key (tag_domain_code)
        references tag_domain (tag_domain_code)
        on delete restrict,
    check (tag_ordinal >= 0)
);

create table if not exists fused_interval_note (
    session_id text not null,
    object_id text not null,
    note_ordinal integer not null,
    note_text text not null,
    primary key (session_id, object_id, note_ordinal),
    foreign key (session_id, object_id)
        references fused_interval (session_id, object_id)
        on delete cascade,
    check (note_ordinal >= 0)
);

-- ============================================================
-- Trigger helpers for cross-table invariants
-- ============================================================

create or replace function assert_stream_modality()
returns trigger
language plpgsql
as $$
declare
    expected_modality text := tg_argv[0];
    actual_modality text;
begin
    select sk.modality_code
      into actual_modality
      from wrist_audio.sensor_stream ss
      join wrist_audio.stream_kind sk
        on sk.stream_kind_code = ss.stream_kind_code
     where ss.session_id = new.session_id
       and ss.stream_id = new.stream_id;

    if actual_modality is null then
        raise exception 'Unknown stream %.% for subtype %', new.session_id, new.stream_id, tg_table_name;
    end if;

    if actual_modality <> expected_modality then
        raise exception 'Subtype table % requires modality %, found % for stream %.%',
            tg_table_name, expected_modality, actual_modality, new.session_id, new.stream_id;
    end if;

    return new;
end;
$$;

create or replace function assert_artifact_modality()
returns trigger
language plpgsql
as $$
declare
    expected_modality text := tg_argv[0];
    actual_modality text;
begin
    select modality_code
      into actual_modality
      from wrist_audio.artifact
     where session_id = new.session_id
       and artifact_id = new.artifact_id;

    if actual_modality is null then
        raise exception 'Unknown artifact %.% for subtype %', new.session_id, new.artifact_id, tg_table_name;
    end if;

    if actual_modality <> expected_modality then
        raise exception 'Subtype table % requires modality %, found % for artifact %.%',
            tg_table_name, expected_modality, actual_modality, new.session_id, new.artifact_id;
    end if;

    return new;
end;
$$;

create or replace function assert_object_kind()
returns trigger
language plpgsql
as $$
declare
    expected_kind text := tg_argv[0];
    actual_kind text;
begin
    select kind_code
      into actual_kind
      from wrist_audio.timeline_object
     where session_id = new.session_id
       and object_id = new.object_id;

    if actual_kind is null then
        raise exception 'Unknown timeline_object %.% for payload table %', new.session_id, new.object_id, tg_table_name;
    end if;

    if actual_kind <> expected_kind then
        raise exception 'Payload table % requires object kind %, found % for object %.%',
            tg_table_name, expected_kind, actual_kind, new.session_id, new.object_id;
    end if;

    return new;
end;
$$;

create or replace function assert_object_ref_expectations()
returns trigger
language plpgsql
as $$
declare
    actual_kind text;
    actual_family wrist_audio.timeline_object_family;
begin
    select o.kind_code, ok.family
      into actual_kind, actual_family
      from wrist_audio.timeline_object o
      join wrist_audio.object_kind ok
        on ok.kind_code = o.kind_code
     where o.session_id = new.session_id
       and o.object_id = new.dst_object_id;

    if actual_kind is null then
        raise exception 'Unknown destination object %.% referenced from %.%',
            new.session_id, new.dst_object_id, new.session_id, new.src_object_id;
    end if;

    if new.expected_kind_code is not null and actual_kind <> new.expected_kind_code then
        raise exception 'Expected destination kind %, found % for object %.%',
            new.expected_kind_code, actual_kind, new.session_id, new.dst_object_id;
    end if;

    if new.expected_family is not null and actual_family <> new.expected_family then
        raise exception 'Expected destination family %, found % for object %.%',
            new.expected_family, actual_family, new.session_id, new.dst_object_id;
    end if;

    return new;
end;
$$;

create or replace function assert_object_artifact_ref_expectations()
returns trigger
language plpgsql
as $$
declare
    actual_role text;
begin
    if new.expected_artifact_role_code is null then
        return new;
    end if;

    select artifact_role_code
      into actual_role
      from wrist_audio.artifact
     where session_id = new.session_id
       and artifact_id = new.dst_artifact_id;

    if actual_role is null then
        raise exception 'Unknown destination artifact %.% referenced from %.%',
            new.session_id, new.dst_artifact_id, new.session_id, new.src_object_id;
    end if;

    if actual_role <> new.expected_artifact_role_code then
        raise exception 'Expected artifact role %, found % for artifact %.%',
            new.expected_artifact_role_code, actual_role, new.session_id, new.dst_artifact_id;
    end if;

    return new;
end;
$$;

create or replace function assert_timeline_object_grid_modality()
returns trigger
language plpgsql
as $$
declare
    object_modality text;
    grid_modality text;
begin
    if new.grid_id is null then
        return new;
    end if;

    select modality_code into object_modality
      from wrist_audio.object_kind
     where kind_code = new.kind_code;

    select modality_code into grid_modality
      from wrist_audio.grid_definition
     where grid_id = new.grid_id;

    if object_modality is null or grid_modality is null then
        raise exception 'Unknown kind or grid for timeline_object %.%', new.session_id, new.object_id;
    end if;

    if object_modality <> grid_modality then
        raise exception 'Grid modality % does not match object modality % for object %.%',
            grid_modality, object_modality, new.session_id, new.object_id;
    end if;

    return new;
end;
$$;

create or replace function assert_artifact_stream_modality()
returns trigger
language plpgsql
as $$
declare
    artifact_modality text;
    stream_modality text;
begin
    select a.modality_code
      into artifact_modality
      from wrist_audio.artifact a
     where a.session_id = new.session_id
       and a.artifact_id = new.artifact_id;

    select sk.modality_code
      into stream_modality
      from wrist_audio.sensor_stream ss
      join wrist_audio.stream_kind sk
        on sk.stream_kind_code = ss.stream_kind_code
     where ss.session_id = new.session_id
       and ss.stream_id = new.stream_id;

    if artifact_modality is null or stream_modality is null then
        raise exception 'Unknown artifact or stream in artifact_stream_ref';
    end if;

    if artifact_modality <> stream_modality then
        raise exception 'Artifact modality % is incompatible with stream modality % for artifact %.%',
            artifact_modality, stream_modality, new.session_id, new.artifact_id;
    end if;

    return new;
end;
$$;

create or replace function assert_sensor_stream_subtype_exists()
returns trigger
language plpgsql
as $$
declare
    actual_modality text;
    subtype_count integer;
begin
    select sk.modality_code
      into actual_modality
      from wrist_audio.stream_kind sk
     where sk.stream_kind_code = new.stream_kind_code;

    if actual_modality is null then
        raise exception 'Unknown stream kind % for stream %.%', new.stream_kind_code, new.session_id, new.stream_id;
    end if;

    subtype_count := 0;

    if exists (
        select 1
          from wrist_audio.audio_stream
         where session_id = new.session_id
           and stream_id = new.stream_id
    ) then
        subtype_count := subtype_count + 1;
    end if;

    if subtype_count <> 1 then
        raise exception 'Exactly one audio subtype row is required for stream %.%, found %',
            new.session_id, new.stream_id, subtype_count;
    end if;

    return null;
end;
$$;

-- Subtype/modality enforcement triggers.
drop trigger if exists audio_stream_modality_check on audio_stream;
create trigger audio_stream_modality_check
before insert or update on audio_stream
for each row execute function assert_stream_modality('audio');

drop trigger if exists sensor_stream_subtype_check on sensor_stream;
create constraint trigger sensor_stream_subtype_check
after insert or update on sensor_stream
DEFERRABLE INITIALLY DEFERRED
for each row execute function assert_sensor_stream_subtype_exists();

drop trigger if exists audio_artifact_profile_modality_check on audio_artifact_profile;
create trigger audio_artifact_profile_modality_check
before insert or update on audio_artifact_profile
for each row execute function assert_artifact_modality('audio');

drop trigger if exists context_segment_kind_check on context_segment;
create trigger context_segment_kind_check
before insert or update on context_segment
for each row execute function assert_object_kind('context_segment');

drop trigger if exists context_change_marker_kind_check on context_change_marker;
create trigger context_change_marker_kind_check
before insert or update on context_change_marker
for each row execute function assert_object_kind('context_change_marker');

drop trigger if exists quality_bin_kind_check on quality_bin;
create trigger quality_bin_kind_check
before insert or update on quality_bin
for each row execute function assert_object_kind('quality_bin');

drop trigger if exists fused_interval_kind_check on fused_interval;
create trigger fused_interval_kind_check
before insert or update on fused_interval
for each row execute function assert_object_kind('fused_interval');

drop trigger if exists object_ref_expectation_check on object_ref;
create trigger object_ref_expectation_check
before insert or update on object_ref
for each row execute function assert_object_ref_expectations();

drop trigger if exists object_artifact_ref_expectation_check on object_artifact_ref;
create trigger object_artifact_ref_expectation_check
before insert or update on object_artifact_ref
for each row execute function assert_object_artifact_ref_expectations();

drop trigger if exists timeline_object_grid_modality_check on timeline_object;
create trigger timeline_object_grid_modality_check
before insert or update on timeline_object
for each row execute function assert_timeline_object_grid_modality();

drop trigger if exists artifact_stream_modality_check on artifact_stream_ref;
create trigger artifact_stream_modality_check
before insert or update on artifact_stream_ref
for each row execute function assert_artifact_stream_modality();

-- ============================================================
-- Seed catalog rows
-- Audio-only runtime scope for now. Future modalities can be added
-- in later migrations by inserting new catalog rows plus sibling subtype tables.
-- ============================================================

insert into modality (modality_code, description) values
    ('audio', 'Acoustic or speech-bearing data')
on conflict (modality_code) do nothing;

insert into stream_kind (stream_kind_code, modality_code, description) values
    ('microphone', 'audio', 'Audio capture stream from a microphone')
on conflict (stream_kind_code) do nothing;

insert into artifact_role (artifact_role_code, description) values
    ('primary_media', 'Primary captured media'),
    ('feature_shard', 'Stored features or descriptors'),
    ('native_output', 'Raw model-native output'),
    ('transcript', 'Transcript or transcript-like text artifact'),
    ('embedding', 'Embedding artifact'),
    ('auxiliary', 'Auxiliary artifact not covered by another role')
on conflict (artifact_role_code) do nothing;

insert into artifact_format (format_code, description, preferred_mime_type) values
    ('wav', 'Waveform Audio File Format', 'audio/wav'),
    ('flac', 'Free Lossless Audio Codec', 'audio/flac'),
    ('opus', 'Opus encoded audio', 'audio/ogg'),
    ('mp3', 'MPEG Layer 3 audio', 'audio/mpeg'),
    ('aac', 'Advanced Audio Coding', 'audio/aac'),
    ('pcm', 'Raw PCM audio', 'application/octet-stream'),
    ('json', 'JSON document', 'application/json'),
    ('ndjson', 'Newline-delimited JSON', 'application/x-ndjson'),
    ('parquet', 'Apache Parquet columnar file', 'application/octet-stream'),
    ('csv', 'Comma-separated values', 'text/csv'),
    ('protobuf', 'Protocol Buffers binary payload', 'application/x-protobuf'),
    ('other', 'Other or unknown artifact format', null)
on conflict (format_code) do nothing;

insert into speech_presence (speech_presence_code, description) values
    ('primary', 'Speech is the dominant foreground signal'),
    ('background', 'Speech is present mainly in the background'),
    ('intermittent', 'Speech appears intermittently'),
    ('absent', 'No speech is present'),
    ('uncertain', 'Speech presence could not be determined reliably')
on conflict (speech_presence_code) do nothing;

insert into correction_type (correction_type_code, description) values
    ('domain_spelling', 'Correction of domain-specific spelling or lexical choice'),
    ('normalization', 'Formatting or normalization correction'),
    ('other', 'Other correction type')
on conflict (correction_type_code) do nothing;

insert into change_type (change_type_code, description) values
    ('acoustic_scene_shift', 'Shift in the acoustic scene'),
    ('acoustic_shift', 'Generic acoustic change'),
    ('speech_density_shift', 'Change in density of speech activity'),
    ('activity_shift', 'Shift in dominant activity'),
    ('uncertain', 'Change detected but not classified confidently')
on conflict (change_type_code) do nothing;

insert into fusion_kind (fusion_kind_code, description) values
    ('speaker_turn', 'Turn attributed to one speaker'),
    ('conversation_interval', 'Conversation interval across one or more turns'),
    ('activity_interval', 'Activity-focused interval'),
    ('episode_interval', 'Longer coherent episode'),
    ('review_interval', 'Interval specifically surfaced for review')
on conflict (fusion_kind_code) do nothing;

insert into tag_domain (tag_domain_code, description) values
    ('acoustic_scene', 'Acoustic scene classification tags'),
    ('sound_event', 'Sound event detection or classification tags'),
    ('change_signal', 'Signals that help explain a context change'),
    ('activity', 'Activity or behavior tags'),
    ('location', 'Location or place tags')
on conflict (tag_domain_code) do nothing;

insert into quality_metric_definition (metric_code, description, modality_code, is_reserved) values
    ('rms_dbfs', 'Root-mean-square loudness in dBFS', 'audio', true),
    ('estimated_snr_db', 'Estimated signal-to-noise ratio in dB', 'audio', true),
    ('speech_ratio', 'Estimated speech proportion within the interval', 'audio', true),
    ('overlap_risk', 'Risk of speaker or source overlap', 'audio', true),
    ('boundary_risk', 'Risk that boundaries are misaligned', 'audio', true),
    ('asr_gap_density', 'Density of ASR gaps or drops', 'audio', true)
on conflict (metric_code) do nothing;

insert into quality_usability_definition (usability_code, description, modality_code, is_reserved) values
    ('asr', 'Usability for ASR and transcript interpretation', 'audio', true),
    ('speaker', 'Usability for speaker-related inference', 'audio', true),
    ('emotion', 'Usability for emotion inference', 'audio', true),
    ('sound_event', 'Usability for sound-event interpretation', 'audio', true),
    ('acoustic_scene', 'Usability for acoustic-scene interpretation', 'audio', true),
    ('media', 'Usability for media and playback interpretation', 'audio', true),
    ('overall', 'Overall usability for downstream interpretation', 'audio', true)
on conflict (usability_code) do nothing;

insert into object_kind (kind_code, family, modality_code, is_durable, payload_table_name, description) values
    ('audio_dsp_bin_observation', 'observation', 'audio', false, null, 'Dense DSP bin observation'),
    ('audio_context_window_evidence', 'evidence', 'audio', false, null, 'Broad acoustic context evidence window'),
    ('audio_asr_word_evidence', 'evidence', 'audio', false, null, 'ASR word-level evidence'),
    ('audio_asr_segment_evidence', 'evidence', 'audio', false, null, 'ASR segment-level evidence'),
    ('audio_asr_correction_evidence', 'evidence', 'audio', false, null, 'ASR correction evidence'),
    ('audio_diarization_segment_evidence', 'evidence', 'audio', false, null, 'Speaker diarization segment evidence'),
    ('audio_speaker_identification_evidence', 'evidence', 'audio', false, null, 'Speaker identification evidence'),
    ('audio_emotion_window_evidence', 'evidence', 'audio', false, null, 'Emotion evidence over a window'),
    ('audio_emotion_segment_evidence', 'evidence', 'audio', false, null, 'Emotion evidence over a segment'),
    ('audio_sound_event_segment_evidence', 'evidence', 'audio', false, null, 'Sound-event segment evidence'),
    ('audio_query_conditioned_sound_evidence', 'evidence', 'audio', false, null, 'Query-conditioned sound refinement evidence'),
    ('audio_text_corpus_match_evidence', 'evidence', 'audio', false, null, 'Text-corpus match evidence for media refinement'),
    ('audio_song_identification_evidence', 'evidence', 'audio', false, null, 'Song identification evidence'),
    ('context_segment', 'derived', 'audio', true, 'context_segment', 'Derived context segment'),
    ('context_change_marker', 'derived', 'audio', true, 'context_change_marker', 'Derived context-change marker'),
    ('quality_bin', 'derived', 'audio', true, 'quality_bin', 'Derived quality and usability bin'),
    ('fused_interval', 'fusion', 'audio', true, 'fused_interval', 'Final fused audio interval')
on conflict (kind_code) do nothing;

insert into grid_definition (grid_id, modality_code, grid_kind, origin_offset_s, bin_size_s, window_size_s, hop_size_s, description) values
    ('audio_base_500ms', 'audio', 'regular_bins', 0.0, 0.5, null, null, 'Canonical dense 500 ms audio grid'),
    ('audio_context_30s_15s', 'audio', 'sliding_windows', 0.0, null, 30.0, 15.0, 'Canonical 30 s / 15 s audio context grid')
on conflict (grid_id) do nothing;

-- ============================================================
-- Backfill remaining FK now that all referenced tables exist
-- ============================================================

do $$
begin
    if not exists (
        select 1
          from pg_constraint
         where conname = 'session_wall_clock_candidate_artifact_ref_artifact_fk'
    ) then
        alter table session_wall_clock_candidate_artifact_ref
            add constraint session_wall_clock_candidate_artifact_ref_artifact_fk
            foreign key (session_id, artifact_id)
            references artifact (session_id, artifact_id)
            on delete cascade;
    end if;
end
$$;

do $$
begin
    if not exists (
        select 1
          from pg_constraint
         where conname = 'session_wall_clock_candidate_artifact_ref_expected_role_fk'
    ) then
        alter table session_wall_clock_candidate_artifact_ref
            add constraint session_wall_clock_candidate_artifact_ref_expected_role_fk
            foreign key (expected_artifact_role_code)
            references artifact_role (artifact_role_code)
            on delete restrict;
    end if;
end
$$;

-- ============================================================
-- Indexes
-- ============================================================

create index if not exists capture_session_by_wearer
    on capture_session (wearer_id);

create unique index if not exists session_wall_clock_candidate_one_primary
    on session_wall_clock_candidate (session_id)
    where is_primary;

create index if not exists sensor_stream_by_kind
    on sensor_stream (stream_kind_code);

create index if not exists sensor_stream_by_device
    on sensor_stream (device_id);

create index if not exists artifact_by_modality_role
    on artifact (session_id, modality_code, artifact_role_code);

create index if not exists artifact_relative_time_gist
    on artifact using gist (relative_time)
    where relative_time is not null;

create index if not exists artifact_stream_ref_by_stream
    on artifact_stream_ref (session_id, stream_id);

create index if not exists timeline_object_by_kind_start
    on timeline_object (session_id, kind_code, start_offset_s);

create index if not exists timeline_object_by_timebase_stream
    on timeline_object (session_id, timebase_reference_stream_id)
    where timebase_reference_stream_id is not null;

create index if not exists timeline_object_relative_time_gist
    on timeline_object using gist (relative_time);

create index if not exists object_stream_ref_by_stream
    on object_stream_ref (session_id, dst_stream_id);

create index if not exists object_artifact_ref_by_artifact
    on object_artifact_ref (session_id, dst_artifact_id);

create index if not exists object_ref_by_destination
    on object_ref (session_id, dst_object_id);

create index if not exists context_segment_tag_by_domain_label
    on context_segment_tag (tag_domain_code, tag_label);

create index if not exists context_change_marker_tag_by_domain_label
    on context_change_marker_tag (tag_domain_code, tag_label);

create index if not exists quality_bin_metric_by_metric
    on quality_bin_metric (metric_code);

create index if not exists quality_bin_usability_by_code
    on quality_bin_usability (usability_code);

create index if not exists fused_interval_by_kind_speaker
    on fused_interval (session_id, fusion_kind_code, speaker_identity, speaker_label);

create index if not exists fused_interval_search_gin
    on fused_interval using gin (search_vector);

create index if not exists fused_interval_tag_by_domain_label
    on fused_interval_tag (tag_domain_code, tag_label);

-- ============================================================
-- Convenience views
-- ============================================================

create or replace view durable_interval_view as
select
    o.session_id,
    o.object_id,
    o.kind_code,
    ok.family,
    ok.modality_code,
    o.start_offset_s,
    o.end_offset_s,
    o.relative_time,
    fi.fusion_kind_code,
    fi.speaker_label,
    fi.speaker_identity,
    fi.transcript_text,
    fi.transcript_corrected_text,
    fi.emotion_label,
    fi.media_present,
    fi.media_kind,
    fi.media_title,
    fi.media_primary_attribution,
    fi.media_identification_confidence,
    fi.narrative_summary,
    fi.review_worthy,
    fi.annotation_worthy,
    o.confidence_overall
from timeline_object o
join object_kind ok
  on ok.kind_code = o.kind_code
join fused_interval fi
  on fi.session_id = o.session_id
 and fi.object_id = o.object_id;

create or replace view quality_bin_view as
select
    o.session_id,
    o.object_id,
    o.start_offset_s,
    o.end_offset_s,
    o.relative_time,
    o.confidence_overall
from timeline_object o
join quality_bin qb
  on qb.session_id = o.session_id
 and qb.object_id = o.object_id;

-- ============================================================
-- Notes
-- ============================================================
-- 1) This schema intentionally keeps the durable current-state payload tables audio-focused,
--    while the core relational model stays modality-extensible.
-- 2) The canonical Python schema may represent some collections as nested lists or dicts;
--    this persistence schema decomposes those into child tables without changing semantics.
-- 3) `CaptureSession.wall_clock_start` maps to the `session_wall_clock_candidate` row with
--    `is_primary = true` when a primary wall-clock estimate is persisted.
-- 4) Additional modalities, stream kinds, artifact formats, object kinds, quality vocabularies,
--    and grids are added by inserting catalog rows plus new subtype/payload tables as needed.
-- 5) Canonical targeted evidence kinds may persist compact payload fields through dedicated payload
--    tables or equivalent generic timeline-object property storage, but typed object/artifact
--    links must still flow through object_ref and object_artifact_ref.
-- 6) If timeline_object or artifact grows very large, use declarative partitioning by session or
--    time window at the table level; the normalized catalog/core model remains unchanged.
