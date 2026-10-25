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
SAMPLE = HERE / 'm5-sample.lisp'
LOAD_LIMITS = (4.0, 8.0, 12.0)
ORDER = [('baseline', 1), ('candidate', 1),
         ('candidate', 2), ('baseline', 2),
         ('baseline', 3), ('candidate', 3),
         ('candidate', 4), ('baseline', 4),
         ('baseline', 5), ('candidate', 5)]


def run(command, cwd=None, env=None):
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                          text=True, check=False)


def source_revision(root):
    result = run(['jj', 'log', '--ignore-working-copy', '-r', '@', '-n', '1',
                  '--no-graph', '-T', 'commit_id'], cwd=root)
    if result.returncode:
        raise ValueError(f'jj revision query failed: {root}')
    return result.stdout.strip()


def check_source(name, root_arg, revision):
    root = Path(root_arg).expanduser().resolve()
    status = run(['jj', 'status', '--no-pager', '--color=never'], cwd=root)
    if status.returncode or 'The working copy has no changes.' not in status.stdout:
        raise ValueError(f'{name} source workspace is not clean')
    if not re.fullmatch(r'[0-9a-f]{40}', revision) or source_revision(root) != revision:
        raise ValueError(f'{name} source revision mismatch')
    listed = run(['jj', '--ignore-working-copy', 'file', 'list', '-r', '@',
                  '-T', 'path ++ "\\0"'], cwd=root)
    files = listed.stdout.split('\0')[:-1]
    if listed.returncode or not files:
        raise ValueError(f'{name} tracked source file list is empty')
    lock = root / 'flake.lock'
    if not lock.is_file():
        raise ValueError(f'{name} flake.lock is missing')
    return {'root': root, 'revision': revision, 'files': files,
            'tree_sha256': source_tree_hash(root, files),
            'flake_lock_sha256': digest(lock)}


def source_tree_hash(root, files):
    digest = hashlib.sha256()
    for name in files:
        path = root / name
        if not path.is_file():
            raise ValueError(f'source file is missing: {path}')
        digest.update(name.encode())
        digest.update(b'\0')
        digest.update(path.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_artifact(arm, values):
    artifact = Path(values['artifact']).expanduser().resolve()
    binary = artifact / 'bin/nerimux'
    core = artifact / 'lib/nerimux/nerimux.core'
    if (not binary.is_file() or not core.is_file()
            or digest(binary) != values['binary_sha256']
            or digest(core) != values['core_sha256']):
        raise ValueError(f'{arm} Nerimux artifact or digest mismatch')
    return {'artifact': str(artifact), 'binary': str(binary),
            'binary_sha256': digest(binary), 'core': str(core),
            'core_sha256': digest(core)}


def validate_target(git, target, expected_version):
    version = run([str(git), '--version'])
    if version.returncode or version.stdout.strip() != expected_version:
        raise ValueError('Git version does not match the pinned version')
    top = run([str(git), '-C', str(target), 'rev-parse', '--show-toplevel'])
    inside = run([str(git), '-C', str(target), 'rev-parse', '--is-inside-work-tree'])
    listed = run([str(git), '-C', str(target), 'worktree', 'list', '--porcelain'])
    status = run([str(git), '-C', str(target), 'status', '--porcelain', '--untracked-files=all'])
    head = run([str(git), '-C', str(target), 'rev-parse', 'HEAD'])
    dot_git = target / '.git'
    path_is_listed = any(line == f'worktree {target}' for line in listed.stdout.splitlines())
    if (top.returncode or Path(top.stdout.strip()).resolve() != target
            or inside.stdout.strip() != 'true' or not dot_git.is_file()
            or listed.returncode or not path_is_listed or status.returncode or head.returncode
            or status.stdout.strip()):
        raise ValueError('target must be a clean linked Git worktree at its root')
    return {'target': str(target), 'git_version': version.stdout.strip(),
            'top_level': top.stdout.strip(), 'head': head.stdout.strip(),
            'linked_worktree': True,
            'worktree_clean': True}


def runtime_env(args, build, sample_dir, preflight=False):
    home = sample_dir / 'home'
    tmp = sample_dir / 'tmp'
    home.mkdir(parents=True, exist_ok=True)
    tmp.mkdir(parents=True, exist_ok=True)
    git = Path(args.git).expanduser().resolve()
    sbcl = Path(args.sbcl).expanduser().resolve()
    env = {'PATH': ':'.join([str(git.parent), str(sbcl.parent),
                             '/usr/bin', '/bin', '/usr/sbin', '/sbin']),
           'HOME': str(home), 'TMPDIR': str(tmp),
           'SBCL_HOME': str(Path(args.sbcl_home).expanduser().resolve()),
           'GIT_OPTIONAL_LOCKS': '0', 'GIT_CONFIG_NOSYSTEM': '1',
           'M5_TARGET': str(Path(args.git_target).expanduser().resolve()),
           'M5_PREFLIGHT_ONLY': '1' if preflight else '0'}
    if not preflight:
        env.update({'M5_WARMUP_OUTPUT': str(sample_dir / 'warmup.out'),
                    'M5_SAMPLE_OUTPUT': str(sample_dir / 'measured.out')})
    return env


def run_core(args, arm, build, sample_dir, preflight=False):
    env = runtime_env(args, build, sample_dir, preflight)
    command = [str(Path(args.sbcl).expanduser().resolve()), '--noinform',
               '--core', build['core'], '--no-sysinit', '--no-userinit',
               '--disable-debugger', '--script', str(SAMPLE)]
    process = run(command, cwd=sample_dir, env=env)
    (sample_dir / 'runner.stdout').write_text(process.stdout)
    (sample_dir / 'runner.stderr').write_text(process.stderr)
    return process


def provenance_line(stdout):
    rows = [line.split('\t') for line in stdout.splitlines()
            if line.startswith('M5_PROVENANCE\t')]
    if len(rows) != 1 or len(rows[0]) != 3:
        raise ValueError('M5 loaded-source provenance record is missing')
    return Path(rows[0][1]).resolve(), Path(rows[0][2]).resolve()


def verify_loaded_sources(stdout, neri_source, pk_source, expected_paths=None):
    neri_asd, pk_asd = provenance_line(stdout)
    neri_root, pk_root = neri_asd.parent, pk_asd.parent
    if expected_paths and (str(neri_asd), str(pk_asd)) != expected_paths:
        raise ValueError('loaded source paths changed after preflight')
    if source_tree_hash(neri_root, neri_source['files']) != neri_source['tree_sha256']:
        raise ValueError('loaded Nerimux source tree does not match pinned workspace')
    if source_tree_hash(pk_root, pk_source['files']) != pk_source['tree_sha256']:
        raise ValueError('loaded process-kit source tree does not match pinned workspace')
    return {'nerimux_asd': str(neri_asd), 'nerimux_source_root': str(neri_root),
            'nerimux_source_revision': neri_source['revision'],
            'nerimux_flake_lock_sha256': neri_source['flake_lock_sha256'],
            'process_kit_asd': str(pk_asd), 'process_kit_source_root': str(pk_root),
            'process_kit_source_revision': pk_source['revision'],
            'process_kit_flake_lock_sha256': pk_source['flake_lock_sha256'],
            'nerimux_tree_sha256': neri_source['tree_sha256'],
            'process_kit_tree_sha256': pk_source['tree_sha256']}


def verify_source_workspace(source):
    root = source['root']
    status = run(['jj', 'status', '--no-pager', '--color=never'], cwd=root)
    if status.returncode or 'The working copy has no changes.' not in status.stdout:
        raise ValueError(f'source workspace changed during run: {root}')
    if source_revision(root) != source['revision']:
        raise ValueError(f'source revision changed during run: {root}')
    if source_tree_hash(root, source['files']) != source['tree_sha256']:
        raise ValueError(f'source tree changed during run: {root}')


def preflight_arm(args, arm, build, neri_source, pk_source, out):
    directory = out / f'preflight-{arm}'
    directory.mkdir()
    process = run_core(args, arm, build, directory, preflight=True)
    provenance = verify_loaded_sources(process.stdout, neri_source, pk_source)
    if (process.returncode or 'M5_PREFLIGHT=ok' not in process.stdout
            or not build['binary_sha256'] or not build['core_sha256']):
        raise ValueError(f'{arm} core source preflight failed')
    (directory / 'provenance.json').write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + '\n')
    return provenance


def parse_load(text):
    values = [float(value) for value in text.split(',')]
    if len(values) != 3 or not all(math.isfinite(value) and value >= 0 for value in values):
        raise ValueError('invalid uptime L1/L5/L15 record')
    return values


def gate(values):
    return all(value <= limit for value, limit in zip(values, LOAD_LIMITS))


def load_spread(records):
    spread = {}
    for phase in ('before', 'after'):
        for index, window in enumerate(('L1', 'L5', 'L15')):
            values = [record[f'load_{phase}_L1_L5_L15'][index] for record in records]
            spread[f'{phase}_{window}'] = {
                'min': min(values), 'max': max(values), 'spread': max(values) - min(values)}
    return spread


def sample_line(stdout):
    for line in stdout.splitlines():
        if line.startswith('M5_SAMPLE\t'):
            fields = line.split('\t')
            if len(fields) == 5:
                return {'status': fields[1], 'elapsed_ms': float(fields[2]),
                        'load_before': parse_load(fields[3]),
                        'load_after': parse_load(fields[4])}
        if line.startswith('M5_REJECT\t'):
            fields = line.split('\t')
            if len(fields) == 4:
                return {'status': 'rejected-before', 'elapsed_ms': None,
                        'load_before': parse_load(fields[2]),
                        'load_after': parse_load(fields[3])}
    raise ValueError('M5 timing/load record is missing')


def run_one(args, arm, pair, label, build, neri_source, pk_source,
            expected_paths, output_reference, out):
    directory = out / label
    directory.mkdir()
    verify_source_workspace(neri_source)
    verify_source_workspace(pk_source)
    process = run_core(args, arm, build, directory)
    raw = {'runner_exit': process.returncode,
           'stdout': process.stdout, 'stderr': process.stderr}
    record_path = directory / 'sample.json'
    try:
        loaded = verify_loaded_sources(process.stdout, neri_source, pk_source, expected_paths)
        verify_source_workspace(neri_source)
        verify_source_workspace(pk_source)
        target_info = validate_target(Path(args.git).expanduser().resolve(),
                                      Path(args.git_target).expanduser().resolve(),
                                      args.git_version)
        if target_info['head'] != args.git_target_head:
            raise ValueError('shared Git worktree HEAD or cleanliness changed during run')
        timing = sample_line(process.stdout)
        warmup = (directory / 'warmup.out').read_bytes()
        measured = (directory / 'measured.out').read_bytes()
        signature = {'bytes': len(measured), 'sha256': hashlib.sha256(measured).hexdigest()}
        warmup_signature = {'bytes': len(warmup), 'sha256': hashlib.sha256(warmup).hexdigest()}
        if (not measured or signature != warmup_signature
                or measured.decode(errors='strict').strip() != str(Path(args.git_target).resolve())
                or timing['elapsed_ms'] <= 0):
            raise ValueError('warmup/measured Git result signature is empty or differs')
        if output_reference is not None and signature != output_reference:
            raise ValueError('paired Git result signature differs across samples')
        record = {'sample_class': 'noise' if pair is None else 'paired',
                  'arm': arm, 'pair': pair, 'label': label,
                  'timing_ms': timing['elapsed_ms'],
                  'load_before_L1_L5_L15': timing['load_before'],
                  'load_after_L1_L5_L15': timing['load_after'],
                  'load_gate_before': gate(timing['load_before']),
                  'load_gate_after': gate(timing['load_after']),
                  'git_result_signature': signature,
                  'warmup_result_signature': warmup_signature,
                  'source_provenance': loaded,
                  'artifact': build['artifact'], 'binary_sha256': build['binary_sha256'],
                  'core_sha256': build['core_sha256'],
                  'git_target': str(Path(args.git_target).resolve()),
                  'git_version': args.git_version, 'sbcl_version': args.sbcl_version,
                  **raw}
        record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        if (process.returncode or timing['status'] != 'ok'
                or not record['load_gate_before'] or not record['load_gate_after']):
            raise ValueError(f'{label} load or runtime gate failed; no retry')
        return record, signature
    except Exception as error:
        failure = {'sample_class': 'noise' if pair is None else 'paired',
                   'arm': arm, 'pair': pair, 'label': label,
                   'runner_exit': process.returncode,
                   'stdout': process.stdout, 'stderr': process.stderr,
                   'error': str(error)}
        if not record_path.exists():
            record_path.write_text(json.dumps(failure, indent=2, sort_keys=True) + '\n')
        raise


def main():
    parser = argparse.ArgumentParser(description='M5 paired process-kit comparison')
    parser.add_argument('--nerimux-source-root', required=True)
    parser.add_argument('--nerimux-source-revision', required=True)
    parser.add_argument('--pk-baseline-source-root', required=True)
    parser.add_argument('--pk-baseline-source-revision', required=True)
    parser.add_argument('--pk-candidate-source-root', required=True)
    parser.add_argument('--pk-candidate-source-revision', required=True)
    parser.add_argument('--baseline-artifact', required=True)
    parser.add_argument('--baseline-binary-sha256', required=True)
    parser.add_argument('--baseline-core-sha256', required=True)
    parser.add_argument('--candidate-artifact', required=True)
    parser.add_argument('--candidate-binary-sha256', required=True)
    parser.add_argument('--candidate-core-sha256', required=True)
    parser.add_argument('--sbcl', required=True)
    parser.add_argument('--sbcl-home', required=True)
    parser.add_argument('--sbcl-version', required=True)
    parser.add_argument('--git', required=True)
    parser.add_argument('--git-version', required=True)
    parser.add_argument('--git-target', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).expanduser().resolve()
    if not out.is_dir() or any(out.iterdir()):
        parser.error('--output-dir must be a new, empty directory')
    if not SAMPLE.is_file() or not Path(args.sbcl).is_file() or not Path(args.git).is_file():
        parser.error('sample Lisp, SBCL, or Git executable is unavailable')
    sbcl_version = run([str(Path(args.sbcl).expanduser().resolve()), '--version'])
    if sbcl_version.returncode or sbcl_version.stdout.strip() != args.sbcl_version:
        parser.error('SBCL version does not match the pinned version')
    neri = check_source('Nerimux', args.nerimux_source_root,
                        args.nerimux_source_revision)
    pk = {
        'baseline': check_source('process-kit baseline', args.pk_baseline_source_root,
                                 args.pk_baseline_source_revision),
        'candidate': check_source('process-kit candidate', args.pk_candidate_source_root,
                                  args.pk_candidate_source_revision)}
    if (pk['baseline']['revision'] == pk['candidate']['revision']
            or pk['baseline']['tree_sha256'] == pk['candidate']['tree_sha256']):
        parser.error('process-kit baseline and candidate sources must differ')
    target = Path(args.git_target).expanduser().resolve()
    target_info = validate_target(Path(args.git).expanduser().resolve(), target,
                                  args.git_version)
    args.git_target_head = target_info['head']
    builds = {
        'baseline': check_artifact('baseline', {'artifact': args.baseline_artifact,
                                                'binary_sha256': args.baseline_binary_sha256,
                                                'core_sha256': args.baseline_core_sha256}),
        'candidate': check_artifact('candidate', {'artifact': args.candidate_artifact,
                                                  'binary_sha256': args.candidate_binary_sha256,
                                                  'core_sha256': args.candidate_core_sha256})}
    for arm in builds:
        builds[arm].update({'nerimux_source_root': str(neri['root']),
                            'nerimux_source_revision': neri['revision'],
                            'process_kit_source_root': str(pk[arm]['root']),
                            'process_kit_source_revision': pk[arm]['revision']})
    (out / 'preflight.json').write_text(json.dumps(
        {'nerimux': {key: value for key, value in neri.items() if key != 'files'},
         'process_kit': {arm: {key: value for key, value in source.items() if key != 'files'}
                         for arm, source in pk.items()},
         'artifacts': builds, 'git_target': target_info,
         'load_gate_L1_L5_L15_max': LOAD_LIMITS}, indent=2, sort_keys=True) + '\n')
    loaded_paths = {}
    for arm in ('baseline', 'candidate'):
        loaded_paths[arm] = preflight_arm(args, arm, builds[arm], neri, pk[arm], out)
    paths = {arm: (loaded_paths[arm]['nerimux_asd'],
                   loaded_paths[arm]['process_kit_asd']) for arm in loaded_paths}
    records = []
    signature = None
    try:
        for index in range(1, 6):
            record, signature = run_one(args, 'baseline', None, f'noise-{index:02d}',
                                        builds['baseline'], neri, pk['baseline'],
                                        paths['baseline'], signature, out)
            records.append(record)
            (out / 'summary.partial.json').write_text(
                json.dumps(records, indent=2, sort_keys=True) + '\n')
        noise_values = [record['timing_ms'] for record in records]
        noise = {'arm': 'baseline', 'samples': len(noise_values),
                 'median_ms': statistics.median(noise_values),
                 'min_ms': min(noise_values), 'max_ms': max(noise_values),
                 'spread_ms': max(noise_values) - min(noise_values),
                 'relative_spread': (max(noise_values) - min(noise_values)) /
                                    statistics.median(noise_values),
                 'load_spread': load_spread(records)}
        for order, (arm, pair) in enumerate(ORDER, 1):
            record, signature = run_one(args, arm, pair, f'pair-{order:02d}',
                                        builds[arm], neri, pk[arm], paths[arm],
                                        signature, out)
            record['order'] = order
            records.append(record)
            (out / 'summary.partial.json').write_text(
                json.dumps(records, indent=2, sort_keys=True) + '\n')
    except Exception as error:
        (out / 'failure.txt').write_text(f'{type(error).__name__}: {error}\n')
        raise
    paired = [record for record in records if record['sample_class'] == 'paired']
    summary = {'status': 'complete', 'noise_screen': noise,
               'pairs': 5, 'samples_per_arm': 5,
               'valid_paired_samples': len(paired),
               'order': [f'{arm}:{pair}' for arm, pair in ORDER],
               'same_git_target': True, 'git_target': str(target),
               'same_git_result_signature': True,
               'git_result_signature': signature,
               'load_gate_L1_L5_L15_max': LOAD_LIMITS,
               'samples': records}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': 'complete', 'noise_screen': noise,
                      'paired_samples': len(paired), 'output_dir': str(out)}, sort_keys=True))


if __name__ == '__main__':
    main()
