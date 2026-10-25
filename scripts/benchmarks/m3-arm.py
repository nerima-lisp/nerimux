from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

EXPECTED_HARNESS_SHA256 = '6b55aecb09b01ee1d0427cf917d4ff255b693201cafb97e5283f6a2a540ae4bb'
SETUP_GATE_S = 60
WAIT_GATE_S = 60
LOAD_LIMITS = (4.0, 8.0, 12.0)


def current_source_sha(root):
    check = subprocess.run(
        ['jj', 'log', '--ignore-working-copy', '-r', '@', '-n', '1',
         '--no-graph', '-T', 'commit_id'],
        cwd=root, capture_output=True, text=True, check=False)
    if check.returncode != 0:
        return None
    value = check.stdout.strip()
    return value or None


def loadavg():
    process = subprocess.run(['uptime'], capture_output=True, text=True, check=False)
    match = re.search(r'load averages?:\s*([0-9]+(?:\.[0-9]+)?)[,\s]+'
                      r'([0-9]+(?:\.[0-9]+)?)[,\s]+'
                      r'([0-9]+(?:\.[0-9]+)?)',
                      process.stdout, re.I)
    if process.returncode != 0 or not match:
        raise RuntimeError('uptime-load-average-unavailable')
    values = [float(value) for value in match.groups()]
    if not all(math.isfinite(value) and value >= 0 for value in values):
        raise RuntimeError('uptime-load-average-invalid')
    return values


def load_gate(values):
    return all(value <= limit for value, limit in zip(values, LOAD_LIMITS))


def tree_rows(text):
    lines = text.splitlines()
    headers = [i for i, line in enumerate(lines)
               if re.search(r'\b(?:Attention|Active|Repositories)\s*\([0-9]+\)', line)]
    if not headers:
        return []
    start = min(headers)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].lstrip().startswith('─')), len(lines))
    rows = []
    for line_index in range(start, end):
        line = lines[line_index]
        candidates = []
        max_indent = min(42, len(line) - 5)
        for indent in range(0, max_indent + 1, 2):
            if line[indent] not in (' ', '>'):
                continue
            if line[indent + 2] != ' ' or line[indent + 3] not in (' ', '▾', '▸') or line[indent + 4] != ' ':
                continue
            body = line[indent + 5:].rstrip()
            if body.strip():
                candidates.append((indent, body, line[indent] == '>'))
        if candidates:
            indent, body, selected = max(candidates, key=lambda item: item[0])
            rows.append({'line_index': line_index, 'indent': indent,
                         'body': body, 'selected': selected})
    return rows


def visible_counts(text):
    org = re.search(r'\b([0-9]+)\s+orgs?\b', text, re.I)
    repos = re.search(r'\bRepositories\s*\(([0-9]+)\)', text)
    worktrees = re.search(r'\b([0-9]+)\s+worktrees?\b', text, re.I)
    return [int(org.group(1)) if org else None,
            int(repos.group(1)) if repos else None,
            int(worktrees.group(1)) if worktrees else None]


def ere_escape(literal):
    special = set('\\.^$*+?()[]{}|')
    return ''.join(('\\' + ch) if ch in special else ch for ch in literal)


def marker_fields(path):
    if not path.is_file():
        raise ValueError(f'missing marker: {path.name}')
    fields = {}
    for line in path.read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            fields[key] = value
    return fields


def verify_inner_markers(live_base, source_sha, server_pid):
    probe = live_base / 'evidence/probe'
    armed = marker_fields(probe / 'server.armed')
    done = marker_fields(probe / 'server.done')
    common = {'role': 'server', 'spawned_by': 'attach', 'lane': 'L1',
              'source_sha': source_sha}
    if any(armed.get(key) != value for key, value in common.items()):
        raise ValueError('server.armed provenance gate failed')
    if any(done.get(key) != value for key, value in common.items()):
        raise ValueError('server.done provenance gate failed')
    required = ('same_connection', 'dispatch_seen', 'dispatch_returned',
                'frame_send_completed', 'frame_snapshot_changed',
                'selection_changed', 'selected_tree_row_visible',
                'selection_advanced_by_one', 'next_row_identity_matches')
    if any(done.get(key) != '1' for key in required):
        raise ValueError('server.done connection/frame/selection gate failed')
    try:
        armed_pid = int(armed['pid'])
        done_pid = int(done['pid'])
        counts = {name: int(done[name]) for name in (
            'tree_entry_count_before', 'tree_entry_count_after',
            'visible_tree_entry_count_before', 'visible_tree_entry_count_after',
            'visible_selectable_row_count_before', 'visible_selectable_row_count_after',
            'selected_row_ordinal_before', 'selected_row_ordinal_after',
            'selected_index_before', 'selected_index_after')}
        timers = {name: float(done[name]) for name in (
            'receive_to_send_sbcl_internal_real_time_elapsed_seconds',
            'dispatch_to_send_sbcl_internal_real_time_elapsed_seconds',
            'receive_to_dispatch_sbcl_internal_real_time_elapsed_seconds',
            'dispatch_internal_sbcl_internal_real_time_elapsed_seconds')}
    except (KeyError, ValueError) as error:
        raise ValueError('server markers have incomplete numeric fields') from error
    if (armed_pid <= 0 or done_pid != armed_pid or done_pid != server_pid
            or counts['tree_entry_count_before'] <= 0
            or counts['tree_entry_count_after'] != counts['tree_entry_count_before']
            or counts['visible_tree_entry_count_before'] <= 0
            or counts['visible_tree_entry_count_after'] != counts['visible_tree_entry_count_before']
            or counts['visible_selectable_row_count_before'] <= 0
            or counts['visible_selectable_row_count_after'] != counts['visible_selectable_row_count_before']
            or counts['selected_row_ordinal_after'] != counts['selected_row_ordinal_before'] + 1
            or counts['selected_index_after'] != counts['selected_index_before'] + 1
            or not all(math.isfinite(value) and value >= 0 for value in timers.values())):
        raise ValueError('server marker PID or before/after signature gate failed')
    return {'armed_path': str(probe / 'server.armed'),
            'done_path': str(probe / 'server.done'), **counts,
            **timers,
            'same_connection': True, 'frame_send_completed': True,
            'frame_snapshot_changed': True, 'selection_changed': True,
            'selected_tree_row_visible': True}


def main(args):
    global ROOT, HARNESS
    ROOT = Path(args.source_root).expanduser().resolve()
    HARNESS = ROOT / 'tests/live/harness'
    expected_source_sha = args.source_revision
    built_binary = Path(args.binary).expanduser().resolve()
    core = Path(args.core).expanduser().resolve()
    sbcl = Path(args.sbcl).expanduser().resolve()
    sbcl_home = Path(args.sbcl_home).expanduser().resolve()
    git = Path(args.git).expanduser().resolve()
    fixture_root = Path(args.fixture_root).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    case_id = args.case
    if not built_binary.is_file() or not os.access(built_binary, os.X_OK):
        raise SystemExit('built binary is unavailable')
    if (not core.is_file() or not sbcl.is_file() or not os.access(sbcl, os.X_OK)
            or not git.is_file() or not os.access(git, os.X_OK)
            or not sbcl_home.is_dir() or not output_dir.is_dir()):
        raise SystemExit('core/SBCL/output input is unavailable')
    built_binary_sha256 = hashlib.sha256(built_binary.read_bytes()).hexdigest()
    built_core_sha256 = hashlib.sha256(core.read_bytes()).hexdigest()
    if built_binary_sha256 != args.binary_sha256 or built_core_sha256 != args.core_sha256:
        raise SystemExit('built binary/core digest mismatch')
    for name, executable, expected in (
            ('SBCL', sbcl, args.sbcl_version), ('Git', git, args.git_version)):
        version = subprocess.run([str(executable), '--version'], capture_output=True,
                                 text=True, check=False)
        if version.returncode or version.stdout.strip() != expected:
            raise SystemExit(f'{name} version does not match pinned version')
    base = Path(tempfile.mkdtemp(prefix=f'{case_id.lower()}.', dir=output_dir))
    live_base = base / 'live'
    launcher = base / 'm3-inner-launcher.sh'
    launch_text = Path(__file__).with_name('m3-inner-launcher.template.sh').read_text()
    replacements = {
        '@@SOURCE_ROOT@@': shlex.quote(str(ROOT)),
        '@@SOURCE_SHA@@': shlex.quote(expected_source_sha),
        '@@CORE_PATH@@': shlex.quote(str(core)),
        '@@SBCL_PATH@@': shlex.quote(str(sbcl)),
        '@@SBCL_HOME@@': shlex.quote(str(sbcl_home)),
        '@@BOOTSTRAP@@': shlex.quote(str(Path(__file__).with_name('m3-inner-bootstrap.lisp'))),
        '@@LIVE_BASE@@': shlex.quote(str(live_base)),
        '@@LAUNCHER@@': shlex.quote(str(launcher)),
    }
    for token, value in replacements.items():
        if token not in launch_text:
            raise RuntimeError(f'inner launcher token absent: {token}')
        launch_text = launch_text.replace(token, value)
    launcher.write_text(launch_text)
    launcher.chmod(0o700)
    instrumented_launcher_sha256 = hashlib.sha256(launcher.read_bytes()).hexdigest()
    binary = launcher
    fixture = base / 'fixture'
    wrapper = base / 'gitconfig-global'
    shim_dir = fixture / 'bin'
    shim_dir.mkdir(parents=True)
    fixture.mkdir(exist_ok=True)
    result = {
        'case': case_id,
        'harness_sha256': EXPECTED_HARNESS_SHA256,
        'source_root': str(ROOT),
        'expected_source_sha': expected_source_sha,
        'source_sha': None, 'source_revision_verified': False,
        'binary_sha256': built_binary_sha256,
        'core_sha256': built_core_sha256,
        'sbcl_path': str(sbcl),
        'sbcl_version': args.sbcl_version,
        'git_path': str(git), 'git_version': args.git_version,
        'fixture_root': str(fixture_root),
        'instrumented_launcher_sha256': instrumented_launcher_sha256,
        'status': 'invalid', 'reason': None,
        'artifact_base': str(base), 'setup_gate_limit_s': SETUP_GATE_S,
        'measured_wait_gate_limit_s': WAIT_GATE_S,
        'wait_poll_sleep_config_ms': 100,
        'command_exits': {}, 'setup_gate_elapsed_sec': None,
        'setup_wait_exit': None, 'selection_wait_exit': None,
        'selection_stable': False, 'measured_keys_exit': None,
        'measured_wait_exit': None, 'elapsed_sec': None,
        'censored_observed_sec': None, 'setup_counts_org_repo_worktree': None,
        'tree_row_count_before': None, 'before_selected_ordinal': None,
        'after_selected_ordinal': None, 'selected_marker_changed': False,
        'target_literal_unique_before': False,
        'target_pattern_precheck_false': False,
        'pane_sha256_before': None, 'pane_sha256_after': None,
        'load_before': None, 'load_after': None,
        'server_socket_pid_count': 0, 'server_pid': None,
        'server_env_root_config_shim_verified': False,
        'self_check_exit': None, 'start_exit': None, 'stop_exit': None,
        'socket_absent_after_stop': None,
    }
    env = os.environ.copy()
    started = False
    try:
        result['source_sha'] = current_source_sha(ROOT)
        result['source_revision_verified'] = (result['source_sha'] == expected_source_sha)
        if not result['source_revision_verified']:
            result['reason'] = 'source-revision-mismatch-or-unavailable'
            return finalize(base, result, 1)
        dirty = subprocess.run(['git', 'status', '--porcelain', '--untracked-files=all'],
                               cwd=ROOT, capture_output=True, text=True, check=False)
        if dirty.returncode != 0 or dirty.stdout.strip():
            result['reason'] = 'source-workspace-not-clean'
            return finalize(base, result, 1)
        if (not HARNESS.is_file()
                or hashlib.sha256(HARNESS.read_bytes()).hexdigest() != EXPECTED_HARNESS_SHA256):
            result['reason'] = 'official-harness-hash-mismatch'
            return finalize(base, result, 1)
        if not binary.is_file() or not os.access(binary, os.X_OK):
            result['reason'] = 'built-binary-unavailable'
            return finalize(base, result, 1)
        wrapper_source = fixture_root / 'gitconfig-global'
        if not wrapper_source.is_file():
            result['reason'] = 'verified-wrapper-artifact-missing'
            return finalize(base, result, 1)
        wrapper_text = wrapper_source.read_text(errors='replace')
        wrapper_roles_ok = (sum(1 for line in wrapper_text.splitlines()
                                if line.lstrip().startswith('path =')) == 2
                           and any(line.lstrip().startswith('excludesFile =')
                                   for line in wrapper_text.splitlines()))
        if not wrapper_roles_ok:
            result['reason'] = 'verified-wrapper-role-check-failed'
            return finalize(base, result, 1)
        shutil.copy2(wrapper_source, wrapper)
        (shim_dir / 'git').write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'export GIT_OPTIONAL_LOCKS=0\n'
            f'exec {shlex.quote(str(git))} "$@"\n')
        (shim_dir / 'git').chmod(0o755)
        ghq = subprocess.run(['ghq', 'root'], capture_output=True, text=True, check=False)
        if ghq.returncode != 0 or not ghq.stdout.strip() or not Path(ghq.stdout.strip()).is_dir():
            result['reason'] = 'actual-ghq-root-unavailable'
            result['ghq_root_query_exit'] = ghq.returncode
            return finalize(base, result, 1)
        ghq_root = ghq.stdout.strip()
        env.update({
            'LIVE_BASE_TMPDIR': str(live_base),
            'LIVE_LANE': 'L1',
            'LIVE_FIXTURE_ROOT': str(fixture),
            'GHQ_ROOT': ghq_root,
            'GIT_CONFIG_GLOBAL': str(wrapper),
            'NERIMUX_BIN': str(binary),
            'PATH': str(shim_dir) + os.pathsep + str(git.parent) + os.pathsep
                    + os.environ.get('PATH', ''),
        })
        result['wrapper_roles_verified'] = True
        result['read_only_git_shim_verified'] = True
        result['fixture_contains_only_git_shim'] = sorted(p.name for p in fixture.iterdir()) == ['bin']
        if not binary.is_file() or not os.access(binary, os.X_OK):
            result['reason'] = 'built-binary-unavailable'
            return finalize(base, result, 1)

        result['self_check_exit'] = call(base, env, 'self-check', ['self-check', 'L1'], result)
        if result['self_check_exit'] != 0:
            result['reason'] = 'self-check-failed'
            return finalize(base, result, 1)

        started = True
        result['start_exit'] = call(base, env, 'start', ['start', 'L1', str(binary)], result)
        if result['start_exit'] != 0:
            result['reason'] = 'start-failed'
            return finalize(base, result, 1)

        gate_start = time.perf_counter_ns()
        result['setup_wait_exit'] = call(
            base, env, 'setup-catalog-wait',
            ['wait-for', 'L1', r'Repositories \([1-9][0-9]*\)', str(SETUP_GATE_S)], result)
        if result['setup_wait_exit'] == 0:
            result['setup_catalog_snap_exit'] = call(
                base, env, 'setup-catalog-snap', ['snap', 'L1', 'M3-catalog'], result)
            catalog_pane = live_base / 'L1' / 'evidence/snapshots/M3-catalog/pane.txt'
            catalog_text = catalog_pane.read_text(errors='replace') if catalog_pane.is_file() else ''
            result['setup_counts_org_repo_worktree'] = visible_counts(catalog_text)
            result['tree_row_count_at_catalog'] = len(tree_rows(catalog_text))
            elapsed_gate = (time.perf_counter_ns() - gate_start) / 1e9
            result['setup_gate_elapsed_sec'] = round(elapsed_gate, 3)
            remaining = int(SETUP_GATE_S - elapsed_gate)
            if remaining > 0:
                result['selection_wait_exit'] = call(
                    base, env, 'setup-selection-wait',
                    ['wait-for', 'L1', r'^[[:space:]]*>', str(remaining)], result)
            else:
                result['selection_wait_exit'] = None
                result['reason'] = 'setup-gate-budget-exhausted-before-selection-wait'
        else:
            result['setup_gate_elapsed_sec'] = round((time.perf_counter_ns() - gate_start) / 1e9, 3)
            result['reason'] = 'catalog-gate-censored'

        if result['selection_wait_exit'] != 0:
            result['reason'] = result['reason'] or 'selected-marker-not-visible-within-60s-setup-gate'
            call(base, env, 'setup-gate-end-snap', ['snap', 'L1', 'M3-gate-end'], result)
            return finalize(base, result, 1)

        stability = []
        for index in range(3):
            snap_id = f'M3-stable-{index}'
            snap_exit = call(base, env, f'stability-snap-{index}', ['snap', 'L1', snap_id], result)
            pane_path = live_base / 'L1' / f'evidence/snapshots/{snap_id}/pane.txt'
            text = pane_path.read_text(errors='replace') if pane_path.is_file() else ''
            rows = tree_rows(text)
            selected = [i for i, row in enumerate(rows) if row['selected']]
            stability.append({'snap_exit': snap_exit, 'text': text, 'rows': rows,
                              'selected': selected,
                              'sha': hashlib.sha256(text.encode()).hexdigest()})
            if index < 2:
                time.sleep(0.05)
        selected_state_ok = all(item['snap_exit'] == 0 and len(item['selected']) == 1
                                for item in stability)
        ordinals = [item['selected'][0] for item in stability if len(item['selected']) == 1]
        selected_bodies = [item['rows'][item['selected'][0]]['body']
                           for item in stability if len(item['selected']) == 1]
        result['selection_stable'] = (selected_state_ok and len(ordinals) == 3
                                      and len(set(ordinals)) == 1
                                      and len(set(selected_bodies)) == 1)
        if not result['selection_stable']:
            result['reason'] = 'selected-marker-or-ordinal-not-stable'
            result['tree_row_count_before'] = len(stability[-1]['rows'])
            result['pane_sha256_before'] = stability[-1]['sha']
            return finalize(base, result, 1)

        socket_path = live_base / 'L1' / 'tmp' / f'nerimux-{os.getuid()}' / 'nerimux-0.sock'
        lsof = subprocess.run(['lsof', '-t', str(socket_path)], capture_output=True, text=True, check=False)
        pids = [line.strip() for line in lsof.stdout.splitlines() if line.strip().isdigit()]
        result['server_socket_pid_count'] = len(pids)
        if len(pids) == 1:
            result['server_pid'] = int(pids[0])
            ps = subprocess.run(['ps', 'eww', '-p', pids[0]], capture_output=True, text=True, check=False)
            ps_env = ps.stdout
            result['server_env_root_config_shim_verified'] = (
                ps.returncode == 0
                and f'GHQ_ROOT={ghq_root}' in ps_env
                and f'GIT_CONFIG_GLOBAL={wrapper}' in ps_env
                and str(shim_dir) in ps_env
            )
        if result['server_socket_pid_count'] != 1 or not result['server_env_root_config_shim_verified']:
            result['reason'] = 'private-server-or-environment-verification-failed'
            return finalize(base, result, 1)

        before = stability[-1]
        rows = before['rows']
        selected_ordinal = ordinals[-1]
        result['before_selected_ordinal'] = selected_ordinal
        result['tree_row_count_before'] = len(rows)
        counts = visible_counts(before['text'])
        result['setup_counts_org_repo_worktree'] = counts
        result['pane_sha256_before'] = before['sha']
        if any(value is None or value <= 0 for value in counts) or len(rows) <= selected_ordinal + 1:
            result['reason'] = 'missing-cardinality-or-next-row'
            return finalize(base, result, 1)
        target = rows[selected_ordinal + 1]['body']
        result['target_literal_unique_before'] = sum(row['body'] == target for row in rows) == 1
        if not result['target_literal_unique_before'] or target == rows[selected_ordinal]['body']:
            result['reason'] = 'next-row-literal-not-unique'
            return finalize(base, result, 1)
        pattern = r'^[[:space:]]*>. . ' + ere_escape(target)
        check = subprocess.run(['grep', '-E', '-q', '--', pattern], input=before['text'],
                               capture_output=True, text=True, check=False)
        result['target_pattern_precheck_false'] = check.returncode == 1
        result['target_pattern_ere_valid'] = check.returncode in (0, 1)
        if not result['target_pattern_ere_valid'] or not result['target_pattern_precheck_false']:
            result['reason'] = 'target-pattern-invalid-or-early-match'
            return finalize(base, result, 1)
        result['target_pattern_sha256'] = hashlib.sha256(pattern.encode()).hexdigest()
        try:
            result['load_before'] = loadavg()
        except RuntimeError:
            result['reason'] = 'uptime-load-average-unavailable-before-sample'
            return finalize(base, result, 1)
        result['load_gate_before_ok'] = load_gate(result['load_before'])
        if not result['load_gate_before_ok']:
            try:
                result['load_after'] = loadavg()
                result['load_gate_after_ok'] = load_gate(result['load_after'])
            except RuntimeError:
                result['load_after'] = None
                result['load_gate_after_ok'] = False
            result['reason'] = 'load-gate-before-sample'
            return finalize(base, result, 1)
        timer_start = time.perf_counter_ns()
        result['measured_keys_exit'] = call(base, env, 'measured-keys', ['keys', 'L1', 'n'], result)
        wait_exit = None
        if result['measured_keys_exit'] == 0:
            wait_exit = call(base, env, 'measured-wait',
                             ['wait-for', 'L1', pattern, str(WAIT_GATE_S)], result,
                             redact=pattern)
        result['measured_wait_exit'] = wait_exit
        timer_end = time.perf_counter_ns()
        observed = (timer_end - timer_start) / 1e9
        try:
            result['load_after'] = loadavg()
        except RuntimeError:
            result['reason'] = 'uptime-load-average-unavailable-after-sample'
            result['outer_observed_sec'] = round(observed, 3)
            return finalize(base, result, 1)
        result['load_gate_after_ok'] = load_gate(result['load_after'])
        result['outer_observed_sec'] = round(observed, 3)
        call(base, env, 'measured-after-snap', ['snap', 'L1', 'M3-after'], result)
        after_pane = live_base / 'L1' / 'evidence/snapshots/M3-after/pane.txt'
        after_text = after_pane.read_text(errors='replace') if after_pane.is_file() else ''
        after_rows = tree_rows(after_text)
        after_selected = [i for i, row in enumerate(after_rows) if row['selected']]
        result['after_selected_ordinal'] = after_selected[0] if len(after_selected) == 1 else None
        result['pane_sha256_after'] = hashlib.sha256(after_text.encode()).hexdigest()
        result['selected_marker_changed'] = (
            len(after_selected) == 1
            and after_selected[0] == selected_ordinal + 1
            and after_rows[after_selected[0]]['body'] == target
        )
        marker_error = None
        if result['selected_marker_changed']:
            try:
                result['inner_marker'] = verify_inner_markers(
                    live_base, result['source_sha'], result['server_pid'])
            except (ValueError, OSError) as error:
                marker_error = str(error)
        if result['measured_keys_exit'] != 0:
            result['reason'] = 'keys-command-failed'
        elif wait_exit != 0:
            result['reason'] = 'official-wait-for-timeout-or-error'
            result['censored_observed_sec'] = round(observed, 3)
        elif not result['load_gate_after_ok']:
            result['reason'] = 'load-gate-after-sample'
        elif marker_error:
            result['reason'] = marker_error
        elif not result['selected_marker_changed']:
            result['reason'] = 'wait-matched-but-selection-ordinal-or-row-mismatch'
        else:
            result['status'] = 'valid'
            result['elapsed_sec'] = round(observed, 3)
            result['reason'] = None
        return finalize(base, result, 0 if result['status'] == 'valid' else 1)
    finally:
        if started:
            result['stop_exit'] = call(base, env, 'stop', ['stop', 'L1', str(binary)], result)
            live_root = Path(env.get('LIVE_BASE_TMPDIR', ''))
            socket_path = live_root / 'L1' / 'tmp' / f'nerimux-{os.getuid()}' / 'nerimux-0.sock'
            result['socket_absent_after_stop'] = not socket_path.exists()
            if result['stop_exit'] != 0 or not result['socket_absent_after_stop']:
                result['cleanup_warning'] = True
            write_result(base, result)


def call(base, env, tag, args, result, redact=None):
    try:
        process = subprocess.run([str(HARNESS), *args], cwd=ROOT, env=env,
                                  capture_output=True, text=True, check=False)
        result.setdefault('command_exits', {})[tag] = process.returncode
        (base / f'{tag}.stdout').write_text(process.stdout)
        stderr = process.stderr
        if redact:
            stderr = stderr.replace(redact, '<redacted-pattern>')
        (base / f'{tag}.stderr').write_text(stderr)
        return process.returncode
    except Exception:
        result.setdefault('command_exits', {})[tag] = None
        return None


def write_result(base, result):
    (base / 'result.json').write_text(json.dumps(result, sort_keys=True) + '\n')


def finalize(base, result, exit_code):
    write_result(base, result)
    print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-root', required=True)
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--binary-sha256', required=True)
    parser.add_argument('--core', required=True)
    parser.add_argument('--core-sha256', required=True)
    parser.add_argument('--sbcl', required=True)
    parser.add_argument('--sbcl-home', required=True)
    parser.add_argument('--sbcl-version', required=True)
    parser.add_argument('--git', required=True)
    parser.add_argument('--git-version', required=True)
    parser.add_argument('--fixture-root', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--case', required=True)
    parsed = parser.parse_args()
    if (not re.fullmatch(r'[0-9a-f]{40}', parsed.source_revision)
            or not re.fullmatch(r'[0-9a-f]{64}', parsed.binary_sha256)
            or not re.fullmatch(r'[0-9a-f]{64}', parsed.core_sha256)
            or not re.fullmatch(r'M3-[0-9]{2}', parsed.case)):
        parser.error('revision, SHA256, or case format is invalid')
    sys.exit(main(parsed))
