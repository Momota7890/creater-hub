-- ============================================================================
-- Center Hub — Initial Database & Smart Storage Schema Migration
-- Migration: 0001_initial_schema.sql
-- Target Platforms: youtube, tiktok, instagram, facebook
-- ============================================================================

-- Enable UUID generation extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================================
-- 1. UTILITY FUNCTIONS & TRIGGERS
-- ============================================================================

-- Automatically update `updated_at` column on row modification
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- ============================================================================
-- 2. CORE TABLES
-- ============================================================================

-- 2.1 PROFILES (1:1 with Supabase auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT,
    display_name TEXT NOT NULL DEFAULT 'Creator',
    avatar_url TEXT,
    timezone TEXT NOT NULL DEFAULT 'UTC',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- Auto-create profile row when a new user signs up via Supabase Auth
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, display_name, avatar_url)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', split_part( COALESCE(NEW.email, 'Creator'), '@', 1 )),
        NEW.raw_user_meta_data->>'avatar_url'
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- 2.2 CONNECTED_PLATFORMS (Stores Fernet-encrypted OAuth credentials)
CREATE TABLE IF NOT EXISTS public.connected_platforms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('youtube', 'tiktok', 'instagram', 'facebook')),
    platform_account_id TEXT NOT NULL,
    account_handle TEXT NOT NULL,
    account_avatar_url TEXT,
    access_token_enc TEXT NOT NULL,
    refresh_token_enc TEXT,
    token_expires_at TIMESTAMPTZ,
    scopes TEXT[] NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'error', 'disconnected')),
    last_synced_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_user_platform_account UNIQUE (user_id, platform, platform_account_id)
);

CREATE TRIGGER trg_connected_platforms_updated_at
    BEFORE UPDATE ON public.connected_platforms
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- 2.3 POSTS (Master record created in Post Studio)
CREATE TABLE IF NOT EXISTS public.posts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    -- `temp_storage_path` points to `ephemeral-videos` bucket and is set to NULL once auto-purged
    temp_storage_path TEXT,
    temp_file_purged_at TIMESTAMPTZ,
    -- `thumbnail_url` points to `permanent-assets` bucket
    thumbnail_url TEXT,
    duration_seconds INTEGER,
    file_size_bytes BIGINT,
    overall_status TEXT NOT NULL DEFAULT 'draft' CHECK (
        overall_status IN ('draft', 'uploading', 'publishing', 'published', 'partial_error', 'failed')
    ),
    scheduled_for TIMESTAMPTZ,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_posts_updated_at
    BEFORE UPDATE ON public.posts
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- 2.4 POST_TARGETS (Per-platform distribution state for a Post)
CREATE TABLE IF NOT EXISTS public.post_targets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    connected_platform_id UUID NOT NULL REFERENCES public.connected_platforms(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('youtube', 'tiktok', 'instagram', 'facebook')),
    status TEXT NOT NULL DEFAULT 'queued' CHECK (
        status IN ('queued', 'uploading', 'processing', 'published', 'failed')
    ),
    external_post_id TEXT,
    external_url TEXT,
    error_message TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_post_connected_platform UNIQUE (post_id, connected_platform_id)
);

CREATE TRIGGER trg_post_targets_updated_at
    BEFORE UPDATE ON public.post_targets
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- 2.5 COMMENTS (Unified Comment Studio inbox & inline reply state)
CREATE TABLE IF NOT EXISTS public.comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    connected_platform_id UUID NOT NULL REFERENCES public.connected_platforms(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('youtube', 'tiktok', 'instagram', 'facebook')),
    external_comment_id TEXT NOT NULL,
    external_post_id TEXT NOT NULL,
    post_title TEXT,
    post_thumbnail_url TEXT,
    author_name TEXT NOT NULL,
    author_handle TEXT,
    author_avatar_url TEXT,
    content TEXT NOT NULL,
    likes_count INTEGER NOT NULL DEFAULT 0,
    is_replied BOOLEAN NOT NULL DEFAULT FALSE,
    our_reply_text TEXT,
    our_reply_external_id TEXT,
    replied_at TIMESTAMPTZ,
    commented_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_platform_external_comment UNIQUE (connected_platform_id, external_comment_id)
);

CREATE TRIGGER trg_comments_updated_at
    BEFORE UPDATE ON public.comments
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- 2.6 ANALYTICS_DAILY (Unified Dashboard time-series & top summary metrics)
CREATE TABLE IF NOT EXISTS public.analytics_daily (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    connected_platform_id UUID NOT NULL REFERENCES public.connected_platforms(id) ON DELETE CASCADE,
    platform TEXT NOT NULL CHECK (platform IN ('youtube', 'tiktok', 'instagram', 'facebook')),
    metric_date DATE NOT NULL,
    views BIGINT NOT NULL DEFAULT 0,
    likes BIGINT NOT NULL DEFAULT 0,
    comments_count BIGINT NOT NULL DEFAULT 0,
    shares BIGINT NOT NULL DEFAULT 0,
    followers_total BIGINT NOT NULL DEFAULT 0,
    followers_delta BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_platform_metric_date UNIQUE (connected_platform_id, metric_date)
);

CREATE TRIGGER trg_analytics_daily_updated_at
    BEFORE UPDATE ON public.analytics_daily
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- 3. PERFORMANCE INDEXES
-- ============================================================================

-- Fast lookup for Connected Platforms by user and status
CREATE INDEX IF NOT EXISTS idx_connected_platforms_user_status
    ON public.connected_platforms (user_id, platform, status);

-- Fast lookup for Posts & Ephemeral Video Cleanup sweeps
CREATE INDEX IF NOT EXISTS idx_posts_user_created
    ON public.posts (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_posts_ephemeral_cleanup
    ON public.posts (created_at)
    WHERE temp_storage_path IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_post_targets_post_status
    ON public.post_targets (post_id, status);

-- Fast lookup for Comment Studio ("Waiting" badge count, Unreplied filter, Platform filter)
CREATE INDEX IF NOT EXISTS idx_comments_user_unreplied
    ON public.comments (user_id, is_replied, platform, commented_at DESC);

CREATE INDEX IF NOT EXISTS idx_comments_user_all
    ON public.comments (user_id, platform, commented_at DESC);

-- Fast lookup for Unified Dashboard date range & platform filters
CREATE INDEX IF NOT EXISTS idx_analytics_daily_user_date_platform
    ON public.analytics_daily (user_id, metric_date DESC, platform);

-- ============================================================================
-- 4. ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connected_platforms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_daily ENABLE ROW LEVEL SECURITY;

-- Profiles Policies
CREATE POLICY "Users can view own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Connected Platforms Policies
CREATE POLICY "Users can view own connected platforms"
    ON public.connected_platforms FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own connected platforms"
    ON public.connected_platforms FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own connected platforms"
    ON public.connected_platforms FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own connected platforms"
    ON public.connected_platforms FOR DELETE
    USING (auth.uid() = user_id);

-- Posts Policies
CREATE POLICY "Users can view own posts"
    ON public.posts FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own posts"
    ON public.posts FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own posts"
    ON public.posts FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own posts"
    ON public.posts FOR DELETE
    USING (auth.uid() = user_id);

-- Post Targets Policies
CREATE POLICY "Users can view own post targets"
    ON public.post_targets FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own post targets"
    ON public.post_targets FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own post targets"
    ON public.post_targets FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own post targets"
    ON public.post_targets FOR DELETE
    USING (auth.uid() = user_id);

-- Comments Policies
CREATE POLICY "Users can view own comments"
    ON public.comments FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can update own comments"
    ON public.comments FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Analytics Daily Policies
CREATE POLICY "Users can view own analytics"
    ON public.analytics_daily FOR SELECT
    USING (auth.uid() = user_id);

-- ============================================================================
-- 5. SMART STORAGE ARCHITECTURE (BUCKETS & STORAGE RLS)
-- ============================================================================

-- 5.1 Permanent Bucket: Thumbnails & Avatars (Public Read, 5MB limit, Image MIME types)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'permanent-assets',
    'permanent-assets',
    TRUE,
    5242880,
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 5.2 Ephemeral Bucket: Raw Videos for Multi-Platform Distribution (Private, 2GB limit, Video MIME types)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'ephemeral-videos',
    'ephemeral-videos',
    FALSE,
    2147483648,
    ARRAY['video/mp4', 'video/quicktime', 'video/webm']
)
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Storage RLS Policies (Scoped to user folder `{user_id}/...`)
CREATE POLICY "Public read access for permanent-assets"
    ON storage.objects FOR SELECT
    USING (bucket_id = 'permanent-assets');

CREATE POLICY "Authenticated users can upload to own folder in permanent-assets"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'permanent-assets'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "Authenticated users can delete own permanent-assets"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'permanent-assets'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "Authenticated users can upload to own folder in ephemeral-videos"
    ON storage.objects FOR INSERT
    WITH CHECK (
        bucket_id = 'ephemeral-videos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "Authenticated users can view own ephemeral-videos"
    ON storage.objects FOR SELECT
    USING (
        bucket_id = 'ephemeral-videos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

CREATE POLICY "Authenticated users can delete own ephemeral-videos"
    ON storage.objects FOR DELETE
    USING (
        bucket_id = 'ephemeral-videos'
        AND auth.uid()::text = (storage.foldername(name))[1]
    );
