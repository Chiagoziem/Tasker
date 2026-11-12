#!/usr/bin/env python3
"""Lightweight CLI task logger.

Logging and listing work offline against a local SQLite file. The server
commands (--push, --create-user, --create-project, --list-projects,
--my-projects) call RPC functions in PostgreSQL (see tasker_rpc.sql) and need:

    pip install psycopg2-binary
    WORK_DATABASE_URL=postgresql://user:pass@host:5432/dbname
"""
import argparse
from datetime import datetime
import os
from pathlib import Path
import sqlite3
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
import sys


# Target the user's Documents directory cross-platform (macOS/Linux/Windows)
DOCS_DIR = Path.home() / "Documents" / "Tasker"
DOCS_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DOCS_DIR / "work_logs.db"


# ---------------------------------------------------------------------------
# Local (SQLite)
# ---------------------------------------------------------------------------
def init_db():
  """Initialize the local database and table, migrating older versions."""
  conn = sqlite3.connect(DB_PATH)
  cursor = conn.cursor()
  cursor.execute("""
        CREATE TABLE IF NOT EXISTS work_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            author TEXT NOT NULL,
            project_name TEXT NOT NULL,
            task TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            pushed INTEGER NOT NULL DEFAULT 0
        )
    """)
  # Older databases were created without the `pushed` column
  columns = [row[1] for row in cursor.execute("PRAGMA table_info(work_logs)")]
  if "pushed" not in columns:
    cursor.execute(
        "ALTER TABLE work_logs ADD COLUMN pushed INTEGER NOT NULL DEFAULT 0"
    )
  conn.commit()
  conn.close()


def log_task(task: str, project: str, author: str):
  """Insert a new task entry into the local database."""
  init_db()
  conn = sqlite3.connect(DB_PATH)
  cursor = conn.cursor()

  timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

  cursor.execute(
      """
        INSERT INTO work_logs (author, project_name, task, timestamp)
        VALUES (?, ?, ?, ?)
    """,
      (author, project, task, timestamp),
  )

  conn.commit()
  conn.close()
  print(f"✅ Logged to [{project}] for {author}: \"{task}\"")


def list_tasks(limit: int = 10):
  """View recent local work logs."""
  init_db()
  conn = sqlite3.connect(DB_PATH)
  cursor = conn.cursor()

  cursor.execute(
      """
        SELECT id, author, project_name, task, timestamp, pushed
        FROM work_logs
        ORDER BY id DESC
        LIMIT ?
    """,
      (limit,),
  )

  rows = cursor.fetchall()
  conn.close()

  if not rows:
    print("No work logs found yet.")
    return

  print(f"\n--- Recent Work Logs (Showing last {len(rows)}) ---")
  for log_id, author, project, task, timestamp, pushed in rows:
    synced = "☁️" if pushed else "  "
    print(
        f"{synced}[{timestamp}] ({author}) 📁 {project.upper()} ➔ {task}"
        f" (ID: {log_id})"
    )
  print("-" * 50)
  print("☁️ = already pushed to server")


# ---------------------------------------------------------------------------
# Server (PostgreSQL RPC functions, see tasker_rpc.sql)
# ---------------------------------------------------------------------------
def clean_db_url(url: str) -> str:
  """Drop Prisma-style params (e.g. ?schema=public) that libpq rejects."""
  parts = urlsplit(url)
  query = [(k, v) for k, v in parse_qsl(parts.query) if k != "schema"]
  return urlunsplit(parts._replace(query=urlencode(query)))


def run_rpc(sql: str, params: tuple = ()):
  """Call a server function and return its (jsonb) result, or exit cleanly."""
  url = os.environ.get("WORK_DATABASE_URL") or os.environ.get("DATABASE_URL")
  if not url:
    sys.exit("❌ WORK_DATABASE_URL is not set. Re-run the installer.")

  try:
    import psycopg2  # imported lazily so offline use never needs the driver
  except ImportError:
    sys.exit("❌ Server commands need psycopg2: pip install psycopg2-binary")

  try:
    conn = psycopg2.connect(clean_db_url(url), connect_timeout=5)
  except psycopg2.Error as e:
    sys.exit(f"❌ Could not reach the server: {str(e).strip()}")

  try:
    with conn:
      with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]
  except psycopg2.Error as e:
    sys.exit(f"❌ Server error: {str(e).strip()}")
  finally:
    conn.close()


def create_user(staff_id: str, username: str):
  """Onboard a user on the server."""
  result = run_rpc("SELECT tasker_create_user(%s, %s)", (staff_id, username))
  if result["created"]:
    print(f"✅ User '{username}' created with staff ID {staff_id}.")
  else:
    print(
        f"ℹ️ Not created: staff ID '{staff_id}' or username '{username}'"
        " already exists."
    )


def create_project(code: str, name: str):
  """Create a project on the server."""
  result = run_rpc("SELECT tasker_create_project(%s, %s)", (code, name))
  if result["created"]:
    print(f"✅ Project '{name}' ({code}) created with ID {result['id']}.")
  else:
    print(f"ℹ️ Not created: project code '{code}' already exists.")


def print_projects(projects, title):
  if not projects:
    print("No projects found.")
    return
  print(f"\n--- {title} ({len(projects)}) ---")
  for p in projects:
    print(f"📁 {p['project_code']:<15} {p['project_name']}  (ID: {p['id']})")
  print("-" * 50)


def list_projects():
  """List every project on the server."""
  print_projects(run_rpc("SELECT tasker_list_projects()"), "All Projects")


def list_my_projects(username: str):
  """List projects the user has pushed work to."""
  projects = run_rpc("SELECT tasker_my_projects(%s)", (username,))
  print_projects(projects, f"Projects for {username}")


def push_logs():
  """Push all unpushed local logs to the server."""
  init_db()
  local = sqlite3.connect(DB_PATH)
  rows = local.execute(
      """
      SELECT id, author, project_name, task, timestamp
      FROM work_logs WHERE pushed = 0 ORDER BY id
      """
  ).fetchall()

  if not rows:
    local.close()
    print("Nothing to push. Everything is already on the server.")
    return

  from psycopg2.extras import Json  # run_rpc reports a missing driver nicely

  logs = [
      {"id": i, "author": a, "project": p, "task": t, "timestamp": ts}
      for i, a, p, t, ts in rows
  ]
  result = run_rpc("SELECT tasker_push_logs(%s)", (Json(logs),))

  try:
    # Only mark rows after the server call has committed successfully
    local.executemany(
        "UPDATE work_logs SET pushed = 1 WHERE id = ?",
        [(i,) for i in result["pushed_ids"]],
    )
    local.commit()
  finally:
    local.close()

  already = len(result["pushed_ids"]) - result["inserted"]
  print(f"✅ Pushed {result['inserted']} new log(s).")
  if already:
    print(f"ℹ️ {already} log(s) were already on the server.")

  skipped = len(rows) - len(result["pushed_ids"])
  if skipped:
    print(f"⚠️ Skipped {skipped} log(s); they stay local until fixed:")
  for name in sorted(set(result["missing_users"])):
    print(f"   - user '{name}' not onboarded: --create-user STAFF_ID -u {name}")
  for name in sorted(set(result["missing_projects"])):
    print(f"   - project '{name}' not found: --create-project CODE \"{name}\"")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
  default_user = os.environ.get("USER") or os.environ.get("USERNAME") or "dev"

  parser = argparse.ArgumentParser(
      description="Lightweight CLI Task Logger for Engineering Teams"
  )
  parser.add_argument(
      "task", nargs="?", help="The task description or what you did"
  )
  parser.add_argument(
      "-p",
      "--project",
      default="general",
      help="Project name or code (default: 'general')",
  )
  parser.add_argument(
      "-u",
      "--user",
      default=default_user,
      help=f"Who did the task / username (default: {default_user})",
  )
  parser.add_argument(
      "-l",
      "--list",
      type=int,
      nargs="?",
      const=10,
      help="List recent local logs (optional: specify limit)",
  )

  server = parser.add_argument_group("server commands")
  server.add_argument(
      "--push",
      action="store_true",
      help="Push all unpushed local logs to the server",
  )
  server.add_argument(
      "--create-user",
      "-cu",
      metavar="STAFF_ID",
      help="Onboard yourself on the server (username comes from -u)",
  )
  server.add_argument(
      "--create-project",
      "--cp",
      nargs=2,
      metavar=("CODE", "NAME"),
      help="Create a project on the server",
  )
  server.add_argument(
      "--list-projects",
      "--lp",
      action="store_true",
      help="List all projects on the server",
  )
  server.add_argument(
      "--my-projects",
      "--mp",
      action="store_true",
      help="List projects you have pushed work to",
  )

  args = parser.parse_args()

  if args.create_user:
    create_user(args.create_user, args.user)
  elif args.create_project:
    create_project(*args.create_project)
  elif args.list_projects:
    list_projects()
  elif args.my_projects:
    list_my_projects(args.user)
  elif args.push:
    push_logs()
  elif args.list is not None:
    list_tasks(args.list)
  elif args.task:
    log_task(args.task, args.project, args.user)
  else:
    parser.print_help()


if __name__ == "__main__":
  main()