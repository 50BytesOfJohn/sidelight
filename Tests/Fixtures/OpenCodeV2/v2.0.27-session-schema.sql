-- Synthetic metadata fixture for OpenCode v2.0.27, commit
-- 1f4d07a4a519185955ae8ab2ea3607805509e386.
-- project/session_v2 DDL matches packages/core/src/database/schema.gen.ts.
-- Timestamp defaults are supplied by application code, not SQLite DEFAULT.
-- All records are invented; no message/event/auth/credential tables.
-- Upstream MIT notice: OpenCode-LICENSE.txt.
PRAGMA foreign_keys = ON;
CREATE TABLE `project` (
  `id` text PRIMARY KEY,
  `worktree` text NOT NULL,
  `vcs` text,
  `name` text,
  `icon_url` text,
  `icon_url_override` text,
  `icon_color` text,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `time_initialized` integer,
  `time_active` integer DEFAULT 0 NOT NULL,
  `time_archived` integer,
  `sandboxes` text NOT NULL,
  `commands` text
);

CREATE TABLE `session_v2` (
  `id` text PRIMARY KEY,
  `project_id` text NOT NULL,
  `workspace_id` text,
  `parent_id` text,
  `fork_session_id` text,
  `fork_boundary` text,
  `slug` text NOT NULL,
  `directory` text NOT NULL,
  `path` text,
  `title` text,
  `version` text NOT NULL,
  `share_url` text,
  `summary_additions` integer,
  `summary_deletions` integer,
  `summary_files` integer,
  `summary_diffs` text,
  `metadata` text,
  `cost` real DEFAULT 0 NOT NULL,
  `tokens_input` integer DEFAULT 0 NOT NULL,
  `tokens_output` integer DEFAULT 0 NOT NULL,
  `tokens_reasoning` integer DEFAULT 0 NOT NULL,
  `tokens_cache_read` integer DEFAULT 0 NOT NULL,
  `tokens_cache_write` integer DEFAULT 0 NOT NULL,
  `revert` text,
  `permission` text,
  `agent` text,
  `model` text,
  `time_created` integer NOT NULL,
  `time_updated` integer NOT NULL,
  `time_idle` integer,
  `time_viewed` integer,
  `idle_outcome` text,
  `time_compacting` integer,
  `time_archived` integer,
  `time_suspended` integer,
  `resume_attempts` integer DEFAULT 0 NOT NULL,
  CONSTRAINT `fk_session_v2_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
);
CREATE INDEX session_v2_project_idx ON session_v2(project_id);
CREATE INDEX session_v2_workspace_idx ON session_v2(workspace_id);
CREATE INDEX session_v2_parent_idx ON session_v2(parent_id);
CREATE INDEX session_v2_time_suspended_idx ON session_v2(time_suspended) WHERE time_suspended IS NOT NULL;

INSERT INTO project (id, worktree, name, time_created, time_updated, sandboxes) VALUES
 ('prj_synthetic', '/tmp/synthetic-project', 'Synthetic project', 1700000000000, 1700000000000, '[]'),
 ('prj_other', '/tmp/other-project', 'Other synthetic project', 1700000000000, 1700000000000, '[]');
INSERT INTO session_v2
 (id, project_id, parent_id, fork_session_id, fork_boundary, slug, directory, path,
  title, version, time_created, time_updated, time_archived, time_idle, time_viewed,
  idle_outcome, time_suspended, resume_attempts) VALUES
 ('ses_synthetic_root', 'prj_synthetic', NULL, NULL, NULL, 'quiet-otter',
  '/tmp/synthetic-project/src/api', 'src/api', 'Synthetic root', '2.0.27',
  1700000000000, 1700000009000, NULL, 1700000008000, 1700000008000, 'succeeded', NULL, 0),
 ('ses_synthetic_child', 'prj_synthetic', 'ses_synthetic_root', NULL, NULL, 'bright-fox',
  '/tmp/synthetic-project/src/api', 'src/api', NULL, '2.0.27',
  1700000001000, 1700000007000, NULL, NULL, NULL, NULL, NULL, 0),
 ('ses_synthetic_fork', 'prj_synthetic', NULL, 'ses_synthetic_root',
  '{"type":"through","messageID":"msg_synthetic_boundary"}', 'new-wren',
  '/tmp/synthetic-project/src/api', 'src/api', 'Synthetic fork', '2.0.27',
  1700000002000, 1700000007000, NULL, NULL, NULL, NULL, NULL, 0),
 ('ses_synthetic_archived', 'prj_synthetic', NULL, NULL, NULL, 'old-wren',
  '/tmp/synthetic-project', '', 'Synthetic archived root', '2.0.27',
  1690000000000, 1690000005000, 1700000006000, NULL, NULL, NULL, NULL, 0),
 ('ses_synthetic_worktree', 'prj_synthetic', NULL, NULL, NULL, 'kind-panda',
  '/tmp/synthetic-worktree', '', 'Synthetic abandoned claim', '2.0.27',
  1700000002000, 1700000004000, NULL, 1700000003000, NULL, 'interrupted', 1700000003500, 2),
 ('ses_synthetic_other_project', 'prj_other', NULL, NULL, NULL, 'small-owl',
  '/tmp/other-project', NULL, 'Other project root', '2.0.27',
  1700000002000, 1700000003000, NULL, NULL, NULL, NULL, NULL, 0);
