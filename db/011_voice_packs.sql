-- CON-010 Voice pack (docs/02 §5, docs/10 §7, docs/11; ADR-049, ADR-051, ADR-072, ADR-077, ADR-078).
-- New numbered migration (ADR-049): db/001..010 are never edited. No dependency on user tables.
-- Backward compatible: adds two publisher-owned tables; nothing references them yet.
--   * voice_pack_versions: one published pack per (locale, version). Immutable and never deleted
--     (ADR-051): changing a sentence, the voice or an audio file means publishing a new version.
--   * voice_cues: the sentences of one pack and their pre-rendered audio (CAF IMA4). storage_key is
--     server-internal (ADR-072): the API returns a short-lived signed URL, never the key.
-- Only the publisher TTS job (BE-007, vbee.vn) writes here; no device or API write path exists
-- (docs/11 §2). The job inserts the version row and all its cues in one transaction.
-- The sentence script lives in fixtures/voice_cues.vi-VN.json; no version is seeded here because a
-- published version needs rendered audio (no placeholder data, AGENTS.md).

CREATE TABLE voice_pack_versions (
    locale text NOT NULL,
    version integer NOT NULL,
    published_at timestamptz NOT NULL,
    voice text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (locale, version),
    CONSTRAINT ck_voice_pack_versions_locale CHECK (locale ~ '^[a-z]{2,3}-[A-Z]{2}$'),
    CONSTRAINT ck_voice_pack_versions_version CHECK (version >= 1),
    CONSTRAINT ck_voice_pack_versions_voice CHECK (char_length(voice) BETWEEN 1 AND 60)
);

CREATE TABLE voice_cues (
    locale text NOT NULL,
    version integer NOT NULL,
    cue_key text NOT NULL,
    text text NOT NULL,
    storage_key text NOT NULL,
    format text NOT NULL DEFAULT 'caf_ima4',
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    duration_ms integer NOT NULL,
    PRIMARY KEY (locale, version, cue_key),
    CONSTRAINT fk_voice_cues_version FOREIGN KEY (locale, version)
        REFERENCES voice_pack_versions (locale, version),
    CONSTRAINT ck_voice_cues_key CHECK (cue_key ~ '^[a-z][a-z0-9_]{0,31}(\.[a-z0-9_]{1,32}){1,3}$'),
    CONSTRAINT ck_voice_cues_text CHECK (char_length(text) BETWEEN 1 AND 80),
    CONSTRAINT ck_voice_cues_storage_key CHECK (char_length(storage_key) BETWEEN 1 AND 512),
    CONSTRAINT ck_voice_cues_format CHECK (format IN ('caf_ima4')),
    CONSTRAINT ck_voice_cues_sha256 CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_voice_cues_byte_size CHECK (byte_size BETWEEN 1 AND 1048576),
    -- iOS plays at most 30 s as a notification sound (ADR-078).
    CONSTRAINT ck_voice_cues_duration CHECK (duration_ms BETWEEN 1 AND 30000)
);

-- Published content is immutable (ADR-051). Inserting cues for an existing version is allowed only in
-- the publishing transaction; afterwards UPDATE/DELETE on either table is rejected.
CREATE FUNCTION voice_pack_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'voice pack %.v% is published and immutable; publish a new version', OLD.locale, OLD.version
        USING ERRCODE = 'restrict_violation', CONSTRAINT = 'ck_voice_pack_immutable';
END $$;

CREATE TRIGGER trg_voice_pack_versions_guard
    BEFORE UPDATE OR DELETE ON voice_pack_versions
    FOR EACH ROW EXECUTE FUNCTION voice_pack_guard();

CREATE TRIGGER trg_voice_cues_guard
    BEFORE UPDATE OR DELETE ON voice_cues
    FOR EACH ROW EXECUTE FUNCTION voice_pack_guard();

-- Cues may only join a version inside the transaction that created it: a later INSERT would silently
-- change a pack clients already cached under the same ETag.
CREATE FUNCTION voice_cues_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM voice_pack_versions v
        WHERE v.locale = NEW.locale AND v.version = NEW.version AND v.xmin = pg_current_xact_id()::xid
    ) THEN
        RAISE EXCEPTION 'voice pack %.v% is already published; publish a new version', NEW.locale, NEW.version
            USING ERRCODE = 'restrict_violation', CONSTRAINT = 'ck_voice_pack_immutable';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_voice_cues_insert_guard
    BEFORE INSERT ON voice_cues
    FOR EACH ROW EXECUTE FUNCTION voice_cues_insert_guard();

-- Latest published pack per locale.
CREATE INDEX ix_voice_pack_versions_latest ON voice_pack_versions (locale, version DESC);
