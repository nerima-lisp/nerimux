from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ARM = HERE / 'm3-arm.py'
HARNESS_SHA256 = '6b55aecb09b01ee1d0427cf917d4ff255b693201cafb97e5283f6a2a540ae4bb'
LOAD_LIMITS = (4.0, 8.0, 12.0)
ORDER = [('baseline', 1), ('candidate', 1),
         ('candidate', 2), ('baseline', 2),
         ('baseline', 3), ('candidate', 3),
         ('candidate', 4), ('baseline', 4),
         ('baseline', 5), ('candidate', 5)]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_ok(values):
    return (isinstance(values, list) and len(values) == 3
            and all(isinstance(value, (int, float)) and math.isfinite(value)
                    and 0 <= value <= limit
                    for value, limit in zip(values, LOAD_LIMITS)))


def git_revision(root):
    result = subprocess.run(
        ['jj', 'log', '--ignore-working-copy', '-r', '@', '-n', '1',
         '--no-graph', '-T', 'commit_id'],
        cwd=root, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f'jj revision query failed: {root}')
    return result.stdout.strip()


def check_build(name, build):
    root = Path(build['source_root']).expanduser().resolve()
    binary = Path(build['binary']).expanduser().resolve()
    core = Path(build['core']).expanduser().resolve()
    harness = root / 'tests/live/harness'
    lock = root / 'flake.lock'
    status = subprocess.run(['jj', 'status', '--no-pager', '--color=never'],
                            cwd=root, capture_output=True, text=True, check=False)
    if status.returncode or 'The working copy has no changes.' not in status.stdout:
        raise ValueError(f'{name} source workspace is not clean')
    if git_revision(root) != build['source_revision']:
        raise ValueError(f'{name} source revision mismatch')
    if not harness.is_file() or digest(harness) != HARNESS_SHA256:
        raise ValueError(f'{name} official harness hash mismatch')
    if not lock.is_file():
        raise ValueError(f'{name} flake.lock is missing')
    if (not binary.is_file() or not core.is_file()
            or digest(binary) != build['binary_sha256']
            or digest(core) != build['core_sha256']):
        raise ValueError(f'{name} binary/core digest mismatch')
    return {'source_root': str(root), 'source_revision': build['source_revision'],
            'harness_sha256': digest(harness), 'binary': str(binary),
            'flake_lock_sha256': digest(lock),
            'binary_sha256': digest(binary), 'core': str(core),
            'core_sha256': digest(core)}


def output_signature(result):
    marker = result['inner_marker']
    signature = [
        result['setup_counts_org_repo_worktree'], result['tree_row_count_before'],
        result['before_selected_ordinal'], result['target_pattern_sha256'],
        marker['tree_entry_count_before'], marker['visible_tree_entry_count_before'],
        marker['visible_selectable_row_count_before'], marker['selected_index_before'],
    ]
    if (not isinstance(signature[0], list) or len(signature[0]) != 3
            or any(not isinstance(value, int) or value <= 0 for value in signature[0])
            or not isinstance(signature[1], int) or signature[1] <= 0
            or not isinstance(signature[2], int) or signature[2] < 0
            or not re.fullmatch(r'[0-9a-f]{64}', signature[3])):
        raise ValueError('M3 before-state signature is incomplete')
    return signature


def load_spread(records):
    spread = {}
    for phase in ('before', 'after'):
        for index, window in enumerate(('L1', 'L5', 'L15')):
            values = [record[f'load_{phase}_L1_L5_L15'][index] for record in records]
            spread[f'{phase}_{window}'] = {
                'min': min(values), 'max': max(values), 'spread': max(values) - min(values)}
    return spread


def run_one(arm, case_number, label, build, args, out, reference_signature):
    command = [sys.executable, str(ARM),
               '--source-root', build['source_root'],
               '--source-revision', build['source_revision'],
               '--binary', build['binary'], '--binary-sha256', build['binary_sha256'],
               '--core', build['core'], '--core-sha256', build['core_sha256'],
               '--sbcl', args.sbcl, '--sbcl-home', args.sbcl_home,
               '--sbcl-version', args.sbcl_version,
               '--git', args.git, '--git-version', args.git_version,
               '--fixture-root', args.fixture_root, '--output-dir', str(out / 'raw'),
               '--case', f'M3-{case_number:02d}']
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    stem = f'{label}-{arm}'
    (out / f'{stem}.stdout').write_text(process.stdout)
    (out / f'{stem}.stderr').write_text(process.stderr)
    try:
        printed = json.loads(process.stdout.strip().splitlines()[-1])
        artifact = Path(printed['artifact_base'])
        result = json.loads((artifact / 'result.json').read_text())
    except (IndexError, KeyError, json.JSONDecodeError, OSError) as error:
        raise ValueError(f'{stem} did not produce its result record') from error
    (out / f'{stem}.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    if (process.returncode != 0 or result.get('status') != 'valid'
            or result.get('source_sha') != build['source_revision']
            or result.get('harness_sha256') != HARNESS_SHA256
            or result.get('binary_sha256') != build['binary_sha256']
            or result.get('core_sha256') != build['core_sha256']
            or result.get('stop_exit') != 0
            or result.get('socket_absent_after_stop') is not True
            or result.get('load_gate_before_ok') is not True
            or result.get('load_gate_after_ok') is not True
            or result.get('sbcl_version') != args.sbcl_version
            or result.get('git_version') != args.git_version
            or not load_ok(result.get('load_before'))
            or not load_ok(result.get('load_after'))):
        raise ValueError(f'{stem} failed source, marker, load, or cleanup gate')
    signature = output_signature(result)
    if reference_signature is not None and signature != reference_signature:
        raise ValueError(f'{stem} output signature differs from prior samples')
    elapsed_internal = result['inner_marker'][
        'receive_to_send_sbcl_internal_real_time_elapsed_seconds']
    if not math.isfinite(elapsed_internal) or elapsed_internal <= 0:
        raise ValueError(f'{stem} internal timer is not positive')
    record = {'label': label, 'arm': arm,
              'source_revision': result['source_sha'],
              'harness_sha256': result['harness_sha256'],
              'binary_sha256': result['binary_sha256'], 'core_sha256': result['core_sha256'],
              'elapsed_internal_sec': elapsed_internal,
              'elapsed_outer_sec': result['elapsed_sec'],
              'load_before_L1_L5_L15': result['load_before'],
              'load_after_L1_L5_L15': result['load_after'],
              'server_armed': result['inner_marker']['armed_path'],
              'server_done': result['inner_marker']['done_path'],
              'same_connection': result['inner_marker']['same_connection'],
              'frame_snapshot_changed': result['inner_marker']['frame_snapshot_changed'],
              'selection_advanced': result['inner_marker']['selection_advanced_by_one'],
              'signature': signature, 'artifact_base': result['artifact_base']}
    return record, signature


def main():
    parser = argparse.ArgumentParser(description='M3 internal paired measurement and noise screen')
    parser.add_argument('--baseline-source-root', required=True)
    parser.add_argument('--baseline-source-revision', required=True)
    parser.add_argument('--baseline-binary', required=True)
    parser.add_argument('--baseline-binary-sha256', required=True)
    parser.add_argument('--baseline-core', required=True)
    parser.add_argument('--baseline-core-sha256', required=True)
    parser.add_argument('--candidate-source-root', required=True)
    parser.add_argument('--candidate-source-revision', required=True)
    parser.add_argument('--candidate-binary', required=True)
    parser.add_argument('--candidate-binary-sha256', required=True)
    parser.add_argument('--candidate-core', required=True)
    parser.add_argument('--candidate-core-sha256', required=True)
    parser.add_argument('--sbcl', required=True)
    parser.add_argument('--sbcl-home', required=True)
    parser.add_argument('--sbcl-version', required=True)
    parser.add_argument('--git', required=True)
    parser.add_argument('--git-version', required=True)
    parser.add_argument('--fixture-root', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).expanduser().resolve()
    if not out.is_dir() or any(out.iterdir()):
        parser.error('--output-dir must be a new, empty directory')
    (out / 'raw').mkdir()
    builds = {
        'baseline': {'source_root': args.baseline_source_root,
                     'source_revision': args.baseline_source_revision,
                     'binary': args.baseline_binary,
                     'binary_sha256': args.baseline_binary_sha256,
                     'core': args.baseline_core,
                     'core_sha256': args.baseline_core_sha256},
        'candidate': {'source_root': args.candidate_source_root,
                      'source_revision': args.candidate_source_revision,
                      'binary': args.candidate_binary,
                      'binary_sha256': args.candidate_binary_sha256,
                      'core': args.candidate_core,
                      'core_sha256': args.candidate_core_sha256},
    }
    provenance = {arm: check_build(arm, build) for arm, build in builds.items()}
    if (provenance['baseline']['flake_lock_sha256']
            != provenance['candidate']['flake_lock_sha256']):
        parser.error('M3 arms must use the same flake.lock')
    (out / 'provenance.json').write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    records = []
    signature = None
    try:
        for index in range(1, 6):
            record, signature = run_one('candidate', index, f'noise-{index:02d}',
                                        builds['candidate'], args, out, signature)
            record['sample_class'] = 'same-code-noise-screen'
            records.append(record)
            (out / 'summary.partial.json').write_text(
                json.dumps(records, indent=2, sort_keys=True) + '\n')
        noise = [item['elapsed_internal_sec'] for item in records]
        noise_summary = {'arm': 'candidate', 'samples': len(noise),
                         'median_sec': statistics.median(noise),
                         'min_sec': min(noise), 'max_sec': max(noise),
                         'spread_sec': max(noise) - min(noise),
                         'relative_spread': (max(noise) - min(noise)) /
                                            statistics.median(noise),
                         'load_spread': load_spread(records)}
        for order, (arm, pair) in enumerate(ORDER, 1):
            record, signature = run_one(arm, pair, f'pair-{order:02d}', builds[arm],
                                        args, out, signature)
            record.update(sample_class='paired', pair=pair, order=order)
            records.append(record)
            (out / 'summary.partial.json').write_text(
                json.dumps(records, indent=2, sort_keys=True) + '\n')
    except Exception as error:
        (out / 'failure.txt').write_text(f'{type(error).__name__}: {error}\n')
        raise
    summary = {'status': 'complete', 'noise_screen': noise_summary,
               'pairs': 5, 'samples_per_arm': 5, 'valid_samples': len(records) - 5,
               'order': [f'{arm}:{pair}' for arm, pair in ORDER],
               'load_gate_L1_L5_L15_max': LOAD_LIMITS,
               'same_output_signature': True, 'output_signature': signature,
               'samples': records}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': 'complete', 'noise_screen': noise_summary,
                      'paired_samples': 10, 'output_dir': str(out)}, sort_keys=True))


if __name__ == '__main__':
    main()
