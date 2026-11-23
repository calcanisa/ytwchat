CREATE TABLE users (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL,
    display_name TEXT NOT NULL,
    email TEXT NOT NULL,
    email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    password_hash TEXT,
    phone_e164 TEXT,
    phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
    avatar_media_id UUID,
    ytw_user_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT users_username_format CHECK (username ~ '^[a-z0-9_]{3,30}$'),
    CONSTRAINT users_display_name_length CHECK (char_length(display_name) BETWEEN 1 AND 60),
    CONSTRAINT users_email_length CHECK (char_length(email) BETWEEN 3 AND 254),
    CONSTRAINT users_phone_format CHECK (phone_e164 IS NULL OR phone_e164 ~ '^\+[1-9][0-9]{6,14}$')
);

CREATE UNIQUE INDEX users_username_key ON users (username);
CREATE UNIQUE INDEX users_email_key ON users (lower(email));
CREATE UNIQUE INDEX users_phone_key ON users (phone_e164) WHERE phone_verified;
CREATE UNIQUE INDEX users_ytw_key ON users (ytw_user_id) WHERE ytw_user_id IS NOT NULL;

CREATE TABLE devices (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    push_token TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    CONSTRAINT devices_platform CHECK (platform IN ('android', 'ios', 'web', 'desktop')),
    CONSTRAINT devices_name_length CHECK (char_length(name) BETWEEN 1 AND 60)
);

CREATE INDEX devices_user_idx ON devices (user_id) WHERE revoked_at IS NULL;

CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ
);

CREATE INDEX sessions_device_idx ON sessions (device_id);

CREATE TABLE access_tokens (
    token_hash BYTEA PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX access_tokens_expiry_idx ON access_tokens (expires_at);

CREATE TABLE refresh_tokens (
    token_hash BYTEA PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ
);

CREATE INDEX refresh_tokens_session_idx ON refresh_tokens (session_id);

CREATE TABLE contacts (
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    contact_user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, contact_user_id),
    CONSTRAINT contacts_not_self CHECK (user_id <> contact_user_id)
);

CREATE TABLE blocks (
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    blocked_user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, blocked_user_id),
    CONSTRAINT blocks_not_self CHECK (user_id <> blocked_user_id)
);

CREATE TABLE key_packages (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    key_package BYTEA NOT NULL,
    is_last_resort BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT key_packages_size CHECK (octet_length(key_package) BETWEEN 1 AND 16384)
);

CREATE INDEX key_packages_device_idx ON key_packages (device_id, is_last_resort, created_at);

CREATE TABLE conversations (
    id UUID PRIMARY KEY,
    kind TEXT NOT NULL,
    created_by UUID REFERENCES users (id) ON DELETE SET NULL,
    epoch BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    direct_key TEXT,
    CONSTRAINT conversations_kind CHECK (kind IN ('direct', 'group'))
);

CREATE UNIQUE INDEX conversations_direct_key ON conversations (direct_key) WHERE direct_key IS NOT NULL;

CREATE TABLE conversation_members (
    conversation_id UUID NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member',
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT conversation_members_role CHECK (role IN ('admin', 'member'))
);

CREATE INDEX conversation_members_user_idx ON conversation_members (user_id);

CREATE TABLE messages (
    id UUID PRIMARY KEY,
    conversation_id UUID NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    sender_user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sender_device_id UUID NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    epoch BIGINT,
    payload BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT messages_kind CHECK (kind IN ('application', 'commit', 'welcome', 'proposal')),
    CONSTRAINT messages_payload_size CHECK (octet_length(payload) BETWEEN 1 AND 262144)
);

CREATE INDEX messages_expiry_idx ON messages (expires_at);
CREATE INDEX messages_conversation_idx ON messages (conversation_id, created_at);

CREATE TABLE message_deliveries (
    message_id UUID NOT NULL REFERENCES messages (id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    PRIMARY KEY (device_id, message_id)
);

CREATE INDEX message_deliveries_message_idx ON message_deliveries (message_id);

CREATE TABLE media (
    id UUID PRIMARY KEY,
    uploader_user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX media_expiry_idx ON media (expires_at);

CREATE TABLE security_events (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID REFERENCES users (id) ON DELETE SET NULL,
    ip INET,
    event TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX security_events_created_idx ON security_events (created_at);
