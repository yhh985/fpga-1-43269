"""Generate a navigable inventory from actual TD declarations, without editing HDL."""
from pathlib import Path
import json
from build_verified import PROJECTS, inputs, validate_record

ROOT = Path(__file__).resolve().parents[1]


def main():
    documents = ROOT / 'docs'
    documents.mkdir(exist_ok=True)
    rows = ['# TD 文件索引', '',
            '由 `tools/generate_code_inventory.py` 从当前 TD 工程与构建输入生成。', '',
            '“工程声明”表示 TD 文件条目，不保证模块实际实例化；其他条目包含保守收集的源码、模型和初始化依赖。', '']
    inventory = {}
    for board, (project, _, _) in PROJECTS.items():
        validate_record(board)
        snapshot = inputs(board)
        declared = set(snapshot['declared_files'])
        inventory[board] = dict(project=f'{board}/{project}', **snapshot)
        rows += [f'## {board}', '', '| 文件 | 来源 |', '|---|---|']
        for path in sorted(snapshot['files']):
            posix = Path(path).as_posix()
            kind = '工程声明' if path in declared else '构建依赖扫描'
            rows.append(f'| [{posix}](../{posix}) | {kind} |')
        rows.append('')
    (documents / 'TD文件索引.md').write_text('\n'.join(rows) + '\n', encoding='utf-8')
    (documents / 'code_inventory.json').write_text(
        json.dumps(inventory, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('PASS: both verified build inputs match; TD inventory regenerated.')


if __name__ == '__main__':
    main()
