-- ============================================================
-- Tasker server setup: tables + RPC functions + restricted role
-- Run once as a superuser:  psql "$ADMIN_URL" -f tasker_rpc.sql
-- Safe to re-run.
-- ============================================================

-- ---------- Tables ----------
CREATE TABLE IF NOT EXISTS users (
    staff_id  VARCHAR(50)  PRIMARY KEY,
    username  VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS projects (
    id            SERIAL       PRIMARY KEY,
    project_code  VARCHAR(50)  NOT NULL UNIQUE,
    project_name  VARCHAR(255) NOT NULL
);

CREATE TABLE IF NOT EXISTS work_logs (
    id          SERIAL       PRIMARY KEY,
    author      VARCHAR(50)  NOT NULL REFERENCES users (staff_id),
    project_id  INTEGER      NOT NULL REFERENCES projects (id),
    task        TEXT         NOT NULL,
    timestamp   TEXT         NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_work_logs_author     ON work_logs (author);
CREATE INDEX IF NOT EXISTS idx_work_logs_project_id ON work_logs (project_id);


-- ---------- RPC: create user ----------
-- Returns {"created": true|false}
CREATE OR REPLACE FUNCTION tasker_create_user(p_staff_id text, p_username text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO users (staff_id, username) VALUES (p_staff_id, p_username);
  RETURN jsonb_build_object('created', true);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('created', false);
END;
$$;


-- ---------- RPC: create project ----------
-- Returns {"created": true|false, "id": <int|null>}
CREATE OR REPLACE FUNCTION tasker_create_project(p_code text, p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id integer;
BEGIN
  INSERT INTO projects (project_code, project_name)
  VALUES (p_code, p_name)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('created', v_id IS NOT NULL, 'id', v_id);
END;
$$;


-- ---------- RPC: list all projects ----------
-- Returns [{"id":..,"project_code":..,"project_name":..}, ...]
CREATE OR REPLACE FUNCTION tasker_list_projects()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object(
      'id', id, 'project_code', project_code, 'project_name', project_name
    ) ORDER BY id),
    '[]'::jsonb)
  FROM projects;
$$;


-- ---------- RPC: projects a user has pushed work to ----------
CREATE OR REPLACE FUNCTION tasker_my_projects(p_username text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object(
      'id', p.id, 'project_code', p.project_code, 'project_name', p.project_name
    ) ORDER BY p.id),
    '[]'::jsonb)
  FROM projects p
  WHERE EXISTS (
    SELECT 1
    FROM work_logs w
    JOIN users u ON u.staff_id = w.author
    WHERE w.project_id = p.id AND u.username = p_username
  );
$$;


-- ---------- RPC: push logs ----------
-- Input:  [{"id":1,"author":"jdoe","project":"Billing","task":"...","timestamp":"..."}, ...]
-- Output: {"pushed_ids":[...], "inserted":n, "missing_users":[...], "missing_projects":[...]}
-- "pushed_ids" are the client's local ids that are now safely on the server
-- (including rows that were already there), so a retry never creates duplicates.
CREATE OR REPLACE FUNCTION tasker_push_logs(p_logs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log        jsonb;
  v_staff_id   text;
  v_project_id integer;
  v_pushed     jsonb   := '[]'::jsonb;
  v_miss_users jsonb   := '[]'::jsonb;
  v_miss_projs jsonb   := '[]'::jsonb;
  v_inserted   integer := 0;
BEGIN
  FOR v_log IN SELECT * FROM jsonb_array_elements(p_logs) LOOP
    SELECT staff_id INTO v_staff_id
      FROM users WHERE username = v_log->>'author';

    IF v_staff_id IS NULL THEN
      v_miss_users := v_miss_users || to_jsonb(v_log->>'author');
      CONTINUE;
    END IF;

    SELECT id INTO v_project_id
      FROM projects
     WHERE lower(project_code) = lower(v_log->>'project')
        OR lower(project_name) = lower(v_log->>'project')
     LIMIT 1;

    IF v_project_id IS NULL THEN
      v_miss_projs := v_miss_projs || to_jsonb(v_log->>'project');
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM work_logs
       WHERE author = v_staff_id
         AND project_id = v_project_id
         AND task = v_log->>'task'
         AND timestamp = v_log->>'timestamp'
    ) THEN
      INSERT INTO work_logs (author, project_id, task, timestamp)
      VALUES (v_staff_id, v_project_id, v_log->>'task', v_log->>'timestamp');
      v_inserted := v_inserted + 1;
    END IF;

    v_pushed := v_pushed || to_jsonb((v_log->>'id')::bigint);
  END LOOP;

  RETURN jsonb_build_object(
    'pushed_ids',       v_pushed,
    'inserted',         v_inserted,
    'missing_users',    v_miss_users,
    'missing_projects', v_miss_projs
  );
END;
$$;


-- ---------- Restricted client role ----------
-- Team members should connect as this role: it can ONLY call the functions
-- above and has no direct access to any table.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tasker_client') THEN
    CREATE ROLE tasker_client LOGIN PASSWORD 'CHANGE_ME';
  END IF;
END
$$;

REVOKE ALL ON users, projects, work_logs FROM tasker_client;
GRANT USAGE ON SCHEMA public TO tasker_client;

REVOKE EXECUTE ON FUNCTION
  tasker_create_user(text, text),
  tasker_create_project(text, text),
  tasker_list_projects(),
  tasker_my_projects(text),
  tasker_push_logs(jsonb)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  tasker_create_user(text, text),
  tasker_create_project(text, text),
  tasker_list_projects(),
  tasker_my_projects(text),
  tasker_push_logs(jsonb)
TO tasker_client;