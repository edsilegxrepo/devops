#!/usr/bin/env python3

import argparse
import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def replace_required(path: Path, old: str, new: str) -> None:
    if not path.is_file():
        fail(f'Target file not found: {path}')
    # Read using UTF-8 and normalize newlines to Unix LF (\n)
    raw_text = path.read_text(encoding='utf-8')
    text = raw_text.replace('\r\n', '\n')
    old_norm = old.replace('\r\n', '\n')
    new_norm = new.replace('\r\n', '\n')

    if new_norm in text:
        return
    if old_norm not in text:
        fail(f'Required patch target not found in {path}')

    # Replace and write out with Unix LF EOL (\n)
    updated_text = text.replace(old_norm, new_norm)
    path.write_bytes(updated_text.encode('utf-8'))


def update_package_json(repo_dir: Path) -> None:
    package_json_path = repo_dir / 'package.json'
    if not package_json_path.is_file():
        fail(f'package.json not found in {repo_dir}')
    data = json.loads(package_json_path.read_text(encoding='utf-8'))

    deps = data.setdefault('dependencies', {})
    if not isinstance(deps, dict):
        deps = {}
        data['dependencies'] = deps
    deps['zod'] = '^4.6.7'
    deps['monaco-editor'] = '^0.57.0'

    overrides = data.setdefault('overrides', {})
    if not isinstance(overrides, dict):
        overrides = {}
        data['overrides'] = overrides
    monaco_overrides = overrides.setdefault('monaco-editor', {})
    if not isinstance(monaco_overrides, dict):
        monaco_overrides = {}
        overrides['monaco-editor'] = monaco_overrides
    monaco_overrides['dompurify'] = '3.4.17'

    # Standard npm 2-space indentation with trailing Unix newline
    formatted = json.dumps(data, indent=2) + '\n'
    package_json_path.write_bytes(formatted.encode('utf-8'))


def update_monaco_workers(repo_dir: Path) -> None:
    config_path = repo_dir / 'src/components/code-snippet/config.ts'
    if not config_path.is_file():
        fail(f'Monaco snippet config not found: {config_path}')

    replacements = {
        'monaco-editor/esm/vs/editor/editor.worker?worker': 'monaco-editor/esm/vs/editor/editor.worker.js?worker',
        'monaco-editor/esm/vs/language/json/json.worker?worker': 'monaco-editor/esm/vs/language/json/json.worker.js?worker',
        'monaco-editor/esm/vs/language/css/css.worker?worker': 'monaco-editor/esm/vs/language/css/css.worker.js?worker',
        'monaco-editor/esm/vs/language/html/html.worker?worker': 'monaco-editor/esm/vs/language/html/html.worker.js?worker',
        'monaco-editor/esm/vs/language/typescript/ts.worker?worker': 'monaco-editor/esm/vs/language/typescript/ts.worker.js?worker',
    }

    for old, new in replacements.items():
        replace_required(config_path, old, new)


def update_vite_alias(repo_dir: Path) -> None:
    vite_config_path = repo_dir / 'vite.config.ts'
    if not vite_config_path.is_file():
        fail(f'Vite config not found: {vite_config_path}')

    old = """    resolve: {\n        alias: {\n            '@': path.resolve(__dirname, './src'),\n        },\n    },\n"""
    new = """    resolve: {\n        alias: {\n            '@': path.resolve(__dirname, './src'),\n            'monaco-editor/esm/vs': path.resolve(\n                __dirname,\n                './node_modules/monaco-editor/esm/vs'\n            ),\n        },\n    },\n"""

    replace_required(vite_config_path, old, new)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo-dir', required=True)
    parser.add_argument(
        '--apply',
        nargs='+',
        choices=['package-json', 'monaco-workers', 'vite-alias', 'all'],
        required=True,
    )
    args = parser.parse_args()

    repo_dir = Path(args.repo_dir)
    actions = set(args.apply)
    if 'all' in actions:
        actions = {'package-json', 'monaco-workers', 'vite-alias'}

    if 'package-json' in actions:
        update_package_json(repo_dir)
    if 'monaco-workers' in actions:
        update_monaco_workers(repo_dir)
    if 'vite-alias' in actions:
        update_vite_alias(repo_dir)


if __name__ == '__main__':
    main()
