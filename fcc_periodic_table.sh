#!/usr/bin/env bash
# freeCodeCamp Periodic Table Database (official CodeRoad v2.0.0)
# Self-contained 5-stage automated runner for the fresh Codespaces project.
#
# bash fcc_periodic_table.sh --run       # run/resume
# bash fcc_periodic_table.sh --status    # progress
# bash fcc_periodic_table.sh --verify    # official tests again
# bash fcc_periodic_table.sh --restart   # redo idempotent stages

set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO="$ROOT/periodic_table"
STATE="$ROOT/.fcc_periodic.progress"
LOG="$ROOT/.fcc_periodic.log"
BACKUP="$ROOT/.fcc_periodic_backup"
PG_USER=${FCC_PERIODIC_PG_USER:-freecodecamp}
GIT_NAME=${FCC_PERIODIC_GIT_NAME:-$(git config --global user.name 2>/dev/null || printf 'freeCodeCamp Student')}
GIT_EMAIL=${FCC_PERIODIC_GIT_EMAIL:-$(git config --global user.email 2>/dev/null || printf 'freecodecamp@example.invalid')}
CURRENT=0

say() { printf '%s\n' "$*"; }
fail() { say "ERROR (stage $CURRENT): $*" >&2; say "Log: $LOG" >&2; exit 1; }

usage() {
  say 'Periodic Table Database - 5-stage runner, 30 official checks' \
    '  bash fcc_periodic_table.sh --run       # auto-complete or resume' \
    '  bash fcc_periodic_table.sh --status    # view checkpoint' \
    '  bash fcc_periodic_table.sh --verify    # rerun official tests' \
    '  bash fcc_periodic_table.sh --restart   # safely redo the 5 stages' \
    '' \
    'Ctrl+C stops safely. No existing database or Git history is reset.' \
    'Only the tutorial-specific bogus atomic number 1000 is removed.'
}

require_environment() {
  command -v psql >/dev/null 2>&1 || fail 'psql is unavailable. Open/start this CodeRoad tutorial first.'
  command -v git >/dev/null 2>&1 || fail 'Git is required.'
  [[ -d "$ROOT/.freeCodeCamp" ]] || fail "Missing .freeCodeCamp: place this script in the Periodic Table tutorial project folder."
  psql -X --username="$PG_USER" --dbname=periodic_table --no-align --tuples-only \
    --set=ON_ERROR_STOP=1 --command 'SELECT 1' >> "$LOG" 2>&1 ||
    fail 'Cannot connect to the supplied periodic_table database. Start the CodeRoad project/setup first. The runner will not recreate or erase it.'
  local needed
  needed=$(scalar "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('elements','properties');") ||
    fail 'Cannot inspect the starter schema.'
  [[ $needed == 2 ]] || fail 'Starter tables missing. Complete/open CodeRoad setup first; the runner does not erase the seeded database.'
}

scalar() {
  local sql=$1
  psql -X --username="$PG_USER" --dbname=periodic_table --no-align --tuples-only \
    --quiet --set=ON_ERROR_STOP=1 --command "$sql" 2>> "$LOG"
}

run_sql() {
  local sql=$1
  psql -X --username="$PG_USER" --dbname=periodic_table \
    --set=ON_ERROR_STOP=1 --command "$sql" >> "$LOG" 2>&1 ||
    fail 'PostgreSQL command failed. See .fcc_periodic.log for the exact error.'
}

column_exists() {
  local table=$1 col=$2
  [[ $(scalar "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='$table' AND column_name='$col';") == 1 ]]
}

constraint_exists() {
  local table=$1 constraint=$2
  [[ $(scalar "SELECT count(*) FROM pg_constraint WHERE conrelid='$table'::regclass AND conname='$constraint';") == 1 ]]
}

unique_exists() {
  local table=$1 col=$2
  [[ $(scalar "SELECT count(*) FROM pg_constraint AS c JOIN pg_attribute AS a ON a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey) WHERE c.conrelid='$table'::regclass AND c.contype='u' AND a.attname='$col' AND array_length(c.conkey,1)=1;") != 0 ]]
}

stage_columns() {
  say '[1/5] Repairing column names, nullability, and unique constraints...'
  if column_exists properties weight; then
    run_sql 'ALTER TABLE properties RENAME COLUMN weight TO atomic_mass;'
  fi
  if column_exists properties melting_point; then
    run_sql 'ALTER TABLE properties RENAME COLUMN melting_point TO melting_point_celsius;'
  fi
  if column_exists properties boiling_point; then
    run_sql 'ALTER TABLE properties RENAME COLUMN boiling_point TO boiling_point_celsius;'
  fi

  run_sql 'ALTER TABLE properties ALTER COLUMN melting_point_celsius SET NOT NULL;'
  run_sql 'ALTER TABLE properties ALTER COLUMN boiling_point_celsius SET NOT NULL;'
  run_sql 'ALTER TABLE elements ALTER COLUMN symbol SET NOT NULL;'
  run_sql 'ALTER TABLE elements ALTER COLUMN name SET NOT NULL;'

  if ! unique_exists elements symbol; then
    run_sql 'ALTER TABLE elements ADD CONSTRAINT elements_symbol_key UNIQUE(symbol);'
  fi
  if ! unique_exists elements name; then
    run_sql 'ALTER TABLE elements ADD CONSTRAINT elements_name_key UNIQUE(name);'
  fi
  if ! constraint_exists properties properties_atomic_number_fkey; then
    run_sql 'ALTER TABLE properties ADD CONSTRAINT properties_atomic_number_fkey FOREIGN KEY(atomic_number) REFERENCES elements(atomic_number);'
  fi
  say '  Basic schema constraints verified.'
}

stage_data() {
  say '[2/5] Normalizing element types, masses, symbols, and values...'
  run_sql '
CREATE TABLE IF NOT EXISTS types (
  type_id INTEGER PRIMARY KEY,
  type VARCHAR(30) NOT NULL UNIQUE
);
INSERT INTO types(type_id, type) VALUES
  (1, '\''metal'\''),
  (2, '\''metalloid'\''),
  (3, '\''nonmetal'\'')
ON CONFLICT (type_id) DO NOTHING;
ALTER TABLE properties ADD COLUMN IF NOT EXISTS type_id INTEGER;'

  if column_exists properties type; then
    run_sql 'UPDATE properties AS p SET type_id=t.type_id FROM types AS t WHERE p.type=t.type AND p.type_id IS DISTINCT FROM t.type_id;'
  fi
  run_sql 'ALTER TABLE properties ALTER COLUMN type_id SET NOT NULL;'
  if ! constraint_exists properties properties_type_id_fkey; then
    run_sql 'ALTER TABLE properties ADD CONSTRAINT properties_type_id_fkey FOREIGN KEY(type_id) REFERENCES types(type_id);'
  fi

  # Drop the original NUMERIC(9,6) scale and store canonical mass values.
  run_sql 'ALTER TABLE properties ALTER COLUMN atomic_mass TYPE NUMERIC USING atomic_mass::NUMERIC;'
  run_sql '
UPDATE properties SET atomic_mass = (
  TRIM(TRAILING '\''.'\'' FROM TRIM(TRAILING '\''0'\'' FROM atomic_mass::TEXT))
)::NUMERIC WHERE atomic_mass IS NOT NULL;
UPDATE properties SET atomic_mass = CASE atomic_number
  WHEN 1 THEN 1.008::NUMERIC
  WHEN 2 THEN 4.0026::NUMERIC
  WHEN 3 THEN 6.94::NUMERIC
  WHEN 4 THEN 9.0122::NUMERIC
  WHEN 5 THEN 10.81::NUMERIC
  WHEN 6 THEN 12.011::NUMERIC
  WHEN 7 THEN 14.007::NUMERIC
  WHEN 8 THEN 15.999::NUMERIC
  ELSE atomic_mass END
WHERE atomic_number BETWEEN 1 AND 8;'

  # Remove the deliberately fictitious row from both related tables.
  run_sql 'DELETE FROM properties WHERE atomic_number=1000;'
  run_sql 'DELETE FROM elements WHERE atomic_number=1000;'

  # Capitalize only the first letter; retain all remaining symbol characters.
  run_sql 'UPDATE elements SET symbol=UPPER(SUBSTRING(symbol FROM 1 FOR 1)) || SUBSTRING(symbol FROM 2) WHERE symbol <> UPPER(SUBSTRING(symbol FROM 1 FOR 1)) || SUBSTRING(symbol FROM 2);'

  run_sql '
INSERT INTO elements(atomic_number,symbol,name) VALUES
  (9, '\''F'\'', '\''Fluorine'\''),
  (10, '\''Ne'\'', '\''Neon'\'')
ON CONFLICT (atomic_number) DO UPDATE SET
  symbol=EXCLUDED.symbol, name=EXCLUDED.name;'
  run_sql '
INSERT INTO properties(atomic_number,atomic_mass,melting_point_celsius,boiling_point_celsius,type_id) VALUES
  (9,18.998,-220,-188.1,(SELECT type_id FROM types WHERE type='\''nonmetal'\'')),
  (10,20.18,-248.6,-246.1,(SELECT type_id FROM types WHERE type='\''nonmetal'\''))
ON CONFLICT (atomic_number) DO UPDATE SET
  atomic_mass=EXCLUDED.atomic_mass,
  melting_point_celsius=EXCLUDED.melting_point_celsius,
  boiling_point_celsius=EXCLUDED.boiling_point_celsius,
  type_id=EXCLUDED.type_id;'

  if column_exists properties type; then
    run_sql 'ALTER TABLE properties DROP COLUMN type;'
  fi
  local elements total_types
  elements=$(scalar 'SELECT COUNT(*) FROM elements;') || fail 'Cannot count elements.'
  total_types=$(scalar 'SELECT COUNT(*) FROM types;') || fail 'Cannot count types.'
  say "  Ready: $elements elements and $total_types types."
  [[ $elements == 10 && $total_types == 3 ]] ||
    fail 'Unexpected row counts. Existing database data is preserved for inspection.'
}

git_run() {
  git -C "$REPO" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
    -c commit.gpgsign=false "$@" >> "$LOG" 2>&1 ||
    fail "Git operation failed: git $* (see .fcc_periodic.log)."
}

commit_count() {
  git -C "$REPO" rev-list --count HEAD 2>/dev/null || printf '0\n'
}

commit_stage() {
  local file=$1 message=$2
  git_run add -- "$file"
  git_run commit -m "$message"
}

create_lookup_script() {
  [[ ! -L "$REPO/element.sh" ]] || fail 'element.sh is a symlink; refusing to overwrite it.'
  mkdir -p "$BACKUP"
  if [[ -f "$REPO/element.sh" && ! -f "$BACKUP/element.sh.original" ]]; then
    cp -p -- "$REPO/element.sh" "$BACKUP/element.sh.original" || fail 'Cannot back up existing element.sh.'
  fi
  cat > "$REPO/element.sh" <<'ELEMENT_SCRIPT'
#! /bin/bash

if [[ -z "${1:-}" ]]; then
  printf 'Please provide an element as an argument.\n'
  exit 0
fi

PSQL="psql --username=freecodecamp --dbname=periodic_table -t --no-align --set=ON_ERROR_STOP=1 -c"

if [[ "$1" =~ ^[0-9]+$ ]]; then
  CONDITION="e.atomic_number=$1"
else
  INPUT_SQL=${1//\'/\'\'}
  CONDITION="e.symbol='$INPUT_SQL' OR e.name='$INPUT_SQL'"
fi

ELEMENT=$($PSQL "
SELECT e.atomic_number,e.name,e.symbol,t.type,p.atomic_mass,p.melting_point_celsius,p.boiling_point_celsius
FROM elements AS e
JOIN properties AS p ON p.atomic_number=e.atomic_number
JOIN types AS t ON p.type_id=t.type_id
WHERE $CONDITION
LIMIT 1;") || exit 1

if [[ -z "$ELEMENT" ]]; then
  printf 'I could not find that element in the database.\n'
  exit 0
fi

IFS='|' read -r NUMBER NAME SYMBOL TYPE MASS MELT BOIL <<< "$ELEMENT"
printf "The element with atomic number %s is %s (%s). It's a %s, with a mass of %s amu. %s has a melting point of %s celsius and a boiling point of %s celsius.\n" \
  "$NUMBER" "$NAME" "$SYMBOL" "$TYPE" "$MASS" "$NAME" "$MELT" "$BOIL"
ELEMENT_SCRIPT
  chmod +x "$REPO/element.sh"
  bash -n "$REPO/element.sh" || fail 'Generated element.sh failed bash syntax check.'
}

stage_repository() {
  say '[3/5] Creating main Git branch, five commits, and element.sh...'
  mkdir -p "$REPO"
  if [[ ! -e "$REPO/.git" ]]; then
    git init -b main "$REPO" >> "$LOG" 2>&1 || fail 'Cannot initialize periodic_table git repository.'
  fi
  local root_path branch n first
  root_path=$(git -C "$REPO" rev-parse --show-toplevel 2>> "$LOG") || fail 'The periodic_table folder is not a Git repository.'
  [[ $root_path == "$REPO" ]] || fail 'Git repository is located outside the periodic_table folder; refusing to change parent repository.'
  n=$(commit_count)
  if (( n > 0 )); then
    first=$(git -C "$REPO" log --reverse --pretty=%s | head -n 1)
    [[ $first == 'Initial commit' ]] || fail 'An existing Git history has a different first commit. Preserving your repository; use a fresh tutorial folder.'
  fi
  branch=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ $branch != main ]]; then
    if git -C "$REPO" show-ref --verify --quiet refs/heads/main; then
      git_run switch main
    else
      git_run branch -M main
    fi
  fi

  if (( n == 0 )); then
    printf '# Periodic Table Database\n\nElement lookup utility for the freeCodeCamp Relational Database project.\n' > "$REPO/README.md"
    commit_stage README.md 'Initial commit'
    n=1
  fi
  if (( n == 1 )); then
    printf '# Data updates\n\n- Element symbols and masses corrected.\n- Properties reference normalized element types.\n- Fluorine and Neon included.\n' > "$REPO/database-notes.md"
    commit_stage database-notes.md 'fix: document normalized element schema'
    n=2
  fi
  if (( n == 2 )); then
    create_lookup_script
    commit_stage element.sh 'feat: add element lookup program'
    n=3
  fi
  if (( n == 3 )); then
    printf '# Lookup examples\n\n- `./element.sh 1`\n- `./element.sh H`\n- `./element.sh Hydrogen`\n- `./element.sh Neon`\n- `./element.sh not-an-element`\n' > "$REPO/examples.md"
    commit_stage examples.md 'test: document element lookup cases'
    n=4
  fi
  if (( n == 4 )); then
    printf '\nRun `./element.sh <atomic-number|symbol|name>` to look up an element.\n' >> "$REPO/README.md"
    commit_stage README.md 'chore: finalize usage instructions'
    n=5
  fi
  [[ -x "$REPO/element.sh" ]] || fail 'element.sh missing or not executable.'
  [[ $(git -C "$REPO" branch --show-current) == main ]] || fail 'The Git branch is not main.'
  [[ -z $(git -C "$REPO" status --porcelain) ]] || fail 'Git working tree has pre-existing or uncommitted changes; inspect the files safely.'
  say "  Git ready: $n commits on main; working tree clean."
}

stage_tests() {
  say '[4/5] Running the 30 official freeCodeCamp checks...'
  [[ -f "$ROOT/.freeCodeCamp/test/1.1.test.js" ]] || fail 'Official test file missing. Open the CodeRoad tutorial first.'
  if [[ ! -x "$ROOT/.freeCodeCamp/node_modules/.bin/mocha" ]]; then
    say '  Installing official test dependencies...'
    (cd "$ROOT/.freeCodeCamp" && npm install --no-audit --no-fund) >> "$LOG" 2>&1 ||
      fail 'Dependency installation failed.'
  fi
  (cd "$ROOT/.freeCodeCamp" && npm run programmatic-test) >> "$LOG" 2>&1 ||
    fail 'At least one official test failed. See .fcc_periodic.log, fix the issue, then rerun --run.'
  say '  All 30 official checks passed.'
}

stage_backup() {
  say '[5/5] Exporting periodic_table.sql outside the Git repository...'
  if [[ -e "$ROOT/periodic_table.sql" ]]; then
    say '  Existing periodic_table.sql left unchanged.'
  elif command -v pg_dump >/dev/null 2>&1; then
    local temp_dump
    temp_dump=$(mktemp "$ROOT/.fcc_periodic_dump.XXXXXX") || fail 'Cannot create safe database dump staging file.'
    if pg_dump -cC --inserts --username="$PG_USER" periodic_table > "$temp_dump" 2>> "$LOG"; then
      mv -n -- "$temp_dump" "$ROOT/periodic_table.sql"
      say '  Saved periodic_table.sql next to the runner.'
    else
      rm -f -- "$temp_dump"
      say '  Warning: pg_dump unavailable or failed; official tests already passed.'
    fi
  else
    say '  Warning: pg_dump not installed; official tests already passed.'
  fi
}

show_status() {
  local saved=0
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || saved=0
  say "Periodic Table: stage $saved/5 saved."
  if (( saved == 5 )); then say 'Complete.'; else say 'Resume: bash fcc_periodic_table.sh --run'; fi
}

run_all() {
  cd -- "$ROOT"
  : >> "$LOG"
  CURRENT=0
  require_environment
  local saved=0 stage
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || fail 'Invalid progress checkpoint. Inspect .fcc_periodic.progress.'
  if (( saved == 5 )); then
    say 'Already completed (5/5). Use --verify to rerun official tests.'
    return
  fi
  for stage in 1 2 3 4 5; do
    (( stage > saved )) || continue
    CURRENT=$stage
    case "$stage" in
      1) stage_columns ;;
      2) stage_data ;;
      3) stage_repository ;;
      4) stage_tests ;;
      5) stage_backup ;;
    esac
    printf '%s\n' "$stage" > "$STATE"
    saved=$stage
    say "  ✓ Stage $stage/5 complete."
  done
  say 'DONE! Periodic Table Database passed all available official checks.'
  say 'If CodeRoad has not advanced, click Run in its tutorial pane.'
}

case "${1:---run}" in
  --run) run_all ;;
  --status) show_status ;;
  --verify) cd -- "$ROOT"; : >> "$LOG"; CURRENT=4; require_environment; stage_tests ;;
  --restart)
    # Resets only this runner's checkpoint. No database or Git reset occurs.
    printf '0\n' > "$STATE"
    run_all
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
