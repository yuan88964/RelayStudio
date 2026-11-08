"""只读检查维护中的规则、示范和链接；不联网、不修改文件、不判断教学效果。"""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
from urllib.parse import unquote

ACTIVE = {'Agent全局配置', '数学笔记', '参考资料', '个人随笔'}
LEGACY = {'整体逻辑检索', '解释清楚检索', '备课检索', '提问链检索', '解释', '认知建立', '笔记撰写', '授课设计', '共用规则', '交流方式', 'AI工程与规范', '接入', '教学工作'}
SKILLS: dict[str, str] = {}
SUFFIXES = {'.md', '.png', '.jpg', '.jpeg', '.svg', '.gif', '.pdf', '.canvas', '.webp', '.json', '.py', '.mjs', '.ps1', '.sh'}


def prose(text: str) -> str:
    text = re.sub(r'^---\s*\n.*?\n---\s*\n', '', text, count=1, flags=re.S)
    text = re.sub(r'^```[^\n]*\n.*?^```\s*$', '', text, flags=re.M | re.S)
    return re.sub(r'`[^`\n]*`', '', text)


def refs(text: str) -> list[tuple[str, bool]]:
    body = prose(text)
    result = [(v, True) for v in re.findall(r'!?\[\[([^\n]+?)\]\]', body)]
    result += [(a or b, False) for a, b in re.findall(r'(?<!!)\[[^\[\]\n]*\]\((?:<([^>]+)>|([^\s)]+))\)', body)]
    return result


def local_dependency(name: str) -> bool:
    return name.startswith((
        '教学管理/', '学习记录/', '学情分析/', '数学题库/', '本机工具/',
        'Agent全局配置/个人档案与本机配置/', 'Agent全局配置/Skills/',
        'Agent全局配置/工具源码/', 'Agent全局配置/维护/', '个人随笔/',
    ))


def managed_sources(root: Path, include_local: bool) -> list[Path]:
    directories = {'数学笔记', '参考资料', '个人随笔'} | LEGACY
    if include_local:
        directories = directories | {'教学管理', '数学题库/强基与竞赛题库'}
    found: set[Path] = set()
    for directory in directories:
        base = root / directory
        if base.is_dir():
            found.update(p for p in base.rglob('*.md') if '_维护' not in p.parts and '.git' not in p.parts)
    # Always include Agent全局配置/Global_Agent_Rules.md and 个人档案与本机配置
    if (root / 'Agent全局配置/Global_Agent_Rules.md').is_file():
        found.add(root / 'Agent全局配置/Global_Agent_Rules.md')
    if include_local and (root / 'Agent全局配置/个人档案与本机配置').is_dir():
        found.update((root / 'Agent全局配置/个人档案与本机配置').rglob('*.md'))
    singles: list[str] = []
    if include_local:
        for skill_dir in (
            'Agent全局配置/Skills/develop',
            'Agent全局配置/Skills/module-design',
            'Agent全局配置/Skills/mermaid-diagrams',
            'Agent全局配置/Skills/writing-for-agents',
            'Agent全局配置/Skills/math-teaching',
            'Agent全局配置/Skills/obsidian-vault-notes',
            'Agent全局配置/Skills/writing-shape',
            'Agent全局配置/Skills/writing-fragments',
            'Agent全局配置/Skills/writing-beats',
            'Agent全局配置/Skills/research',
        ):
            base = root / skill_dir
            if base.is_dir():
                found.update(base.rglob('*.md'))
    found.update(root / name for name in singles if (root / name).is_file())
    return sorted(found)


def resolve_target(root: Path, source: str, raw: str, wiki: bool) -> tuple[str, str] | None:
    value = unquote(raw.strip().strip('<>'))
    if wiki:
        value = value.split('|', 1)[0].rstrip('\\')
    if value.lower().startswith('file:///'):
        name, _, anchor = value[8:].partition('#')
        try:
            rel = Path(name).resolve().relative_to(root).as_posix()
        except ValueError:
            return None
        if re.fullmatch(r'L\d+(?:-L?\d+)?', anchor):
            anchor = ''
        return rel, anchor
    if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]+:', value) or value.startswith('//'):
        return None
    name, _, anchor = value.partition('#')
    if re.match(r'^[a-zA-Z]:[\\/]', name):
        p = Path(name)
    else:
        p = root / source if not name else (root / name if wiki else root / Path(source).parent / name)
    if wiki and p.suffix.lower() not in SUFFIXES:
        p = Path(str(p) + '.md')
    return p.resolve().relative_to(root).as_posix(), anchor


def has_anchor(text: str, anchor: str) -> bool:
    if anchor.startswith('^'):
        return bool(re.search(r'(?m)(?:^|\s)\^' + re.escape(anchor[1:]) + r'\s*$', text))
    headings = set(re.findall(r'(?m)^#{1,6}\s+(.+?)\s*#*\s*$', prose(text)))
    if anchor in headings:
        return True
    # Also support GitHub-style slug anchors (e.g. #status-and-evidence, #grounding)
    slugs = {
        re.sub(r'[^\w\u4e00-\u9fff\- ]+', '', h.lower()).strip().replace(' ', '-')
        for h in headings
    }
    return anchor.lower() in slugs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[4])
    parser.add_argument('--local', action='store_true', help='增加本地教学记录和两份材料导航，排除维护备份')
    parser.add_argument('--known-external', type=Path, help='兼容已核对外部清单；只核对存在性，不假称读过正文')
    args = parser.parse_args()
    root = args.root.resolve()
    errors: list[str] = []
    warnings: set[str] = set()
    optional: set[str] = set()
    cache: dict[str, str] = {}
    try:
        known = json.loads(args.known_external.read_text(encoding='utf-8-sig')) if args.known_external else {}
        if not isinstance(known, dict) or any(not isinstance(k, str) or not re.fullmatch(r'[0-9a-f]{40}', str(v)) for k, v in known.items()):
            raise ValueError('外部清单必须是路径到40位Git blob SHA的JSON对象')
        mapping = {}
        sources = [p.relative_to(root).as_posix() for p in managed_sources(root, args.local)]
    except (OSError, UnicodeError, ValueError) as exc:
        print(json.dumps({'errors': [str(exc)], 'scope': '读取检查输入失败'}, ensure_ascii=False))
        return 2

    def read(name: str) -> str | None:
        if name in cache:
            return cache[name]
        try:
            cache[name] = (root / name).read_text(encoding='utf-8-sig')
            return cache[name]
        except (OSError, UnicodeError) as exc:
            errors.append(f'无法读取 {name}: {exc}')
            return None

    checked_links = 0
    for source in sources:
        text = read(source)
        if text is None:
            continue
        if source.split('/', 1)[0] in LEGACY:
            errors.append(f'旧目录文件仍存在: {source}')
        for raw, wiki in refs(text):
            try:
                target = resolve_target(root, source, raw, wiki)
            except ValueError:
                errors.append(f'{source}: 引用越出仓库 {raw}')
                continue
            if target is None:
                continue
            dest, anchor = target
            checked_links += 1
            if not args.local and local_dependency(dest):
                optional.add(dest)
                continue
            if not (root / dest).is_file():
                if dest in known:
                    warnings.add(f'仅由外部清单确认存在，未检查正文及锚点: {dest}')
                else:
                    errors.append(f'{source}: 目标不存在 {dest}')
                continue
            if dest.split('/', 1)[0] in LEGACY:
                errors.append(f'{source}: 依赖旧入口 {dest}')
            if anchor:
                if not dest.endswith('.md'):
                    warnings.add(f'未检查非Markdown锚点: {dest}#{anchor}')
                    continue
                target_text = read(dest)
                if target_text is not None and not has_anchor(target_text, anchor):
                    errors.append(f'{source}: 锚点不存在 {dest}#{anchor}')

    found = {Path(p).parent.name for p in sources if p.startswith('.agents/skills/') and p.endswith('/SKILL.md')}
    if found != set(SKILLS):
        errors.append(f'skill集合不符: {sorted(found)}')

    report = {
        'mode': 'local' if args.local else 'shared_rules',
        'checked_markdown_files': len(sources), 'checked_internal_links': checked_links,
        'additional_anchor_texts_read': len(set(cache) - set(sources)),
        'skills': len(found), 'legacy_redirects': 0,
        'optional_local_dependencies_not_checked': sorted(optional),
        'errors': errors, 'warnings': sorted(warnings),
        'scope': '定向静态链接及锚点检查；不评判数学、外部路径可用性、宿主触发或教学效果',
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
