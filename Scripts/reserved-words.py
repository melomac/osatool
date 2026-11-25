"""
Finds the words that cannot be the name of a variable without bars.

    python3 Scripts/reserved-words.py Terminology/language.json \\
        Terminology/applications.json <work folder> [--write]

Every single word of the dictionaries, and the reserved words of the
language, is written as `set |word| to 1`. The script is compiled, and
osadecompile prints it back: it keeps the bars only where they are
needed.

osadecompile also takes the bars off a few words that do not compile
without them: `set relative to 1` (`relative to` is one word of the
language), `set volume to 1` (`set volume` is a command). So every word
it prints without bars is compiled that way too, and is kept when the
compiler refuses it or makes another script than with bars.

With --write, the list goes into the language table as
`reserved_words`; run Scripts/embed-terminology.sh after it.

It calls osacompile and osadecompile, so it works only with
OSATOOL_APPLE_TOOLS set, like the tests that call Apple's tools.
"""
import json
import os
import re
import subprocess
import sys

if not os.environ.get('OSATOOL_APPLE_TOOLS'):
    sys.exit('reserved-words.py: set OSATOOL_APPLE_TOOLS=1 to let osacompile run')

language, applications, work = sys.argv[1:4]
os.makedirs(work, exist_ok=True)
words = set('''about above after against and apart around as aside at back before beginning behind below beneath beside
between but by considering contain contains continue copy div does eighth else end equal equals error every exit false
fifth first for fourth from front get given global if ignoring in instead into is it its last local me middle mod my
ninth not of on onto or out over prop property put ref reference repeat return returning script second set seventh
since sixth some tell tenth that the then third through thru timeout times to transaction true try until where while
whose with without item items length name path record class missing result text string number list date file alias
application app id version pi tab space quote linefeed minutes hours days weeks yes no ask null me it parent
st nd rd th relative'''.split())


def collect(node):
    if isinstance(node, dict):
        name = node.get('name')
        if isinstance(name, str):
            for word in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', name):
                words.add(word)
        for value in node.values():
            collect(value)
    elif isinstance(node, list):
        for value in node:
            collect(value)


table = json.load(open(language))
collect(table)
collect(json.load(open(applications)))
# A name keeps the capital letters it is first written with, so only lower case is tried.
ordered = sorted({word.lower() for word in words})
reserved = []
for start in range(0, len(ordered), 300):
    part = ordered[start:start + 300]
    source = os.path.join(work, 'words.applescript')
    open(source, 'w').write('\n'.join(f'set |{word}| to 1' for word in part) + '\n')
    done = subprocess.run(['osacompile', '-o', os.path.join(work, 'words.scpt'), source], capture_output=True, text=True)
    if done.returncode != 0:
        print('does not compile:', done.stderr.strip()[-200:])
        sys.exit(1)
    printed = subprocess.run(['osadecompile', os.path.join(work, 'words.scpt')], capture_output=True, text=True).stdout.strip().splitlines()
    assert len(printed) == len(part), (len(printed), len(part))
    for word, line in zip(part, printed):
        if line.startswith('set |'):
            reserved.append(word.lower())


def compiled(lines):
    """The script that `lines` compile to, run-only, or None when the compiler refuses them."""
    source = os.path.join(work, 'bare.applescript')
    output = os.path.join(work, 'bare.scpt')
    open(source, 'w').write('\n'.join(lines) + '\n')
    done = subprocess.run(['osacompile', '-x', '-o', output, source], capture_output=True)
    return open(output, 'rb').read() if done.returncode == 0 else None


def need_bars(part):
    """The words of `part` that do not compile without bars to what they compile to with bars."""
    bare = compiled([f'set {word} to 1' for word in part])
    if bare is not None and bare == compiled([f'set |{word}| to 1' for word in part]):
        return []
    if len(part) == 1:
        return part
    half = len(part) // 2
    return need_bars(part[:half]) + need_bars(part[half:])


rest = [word for word in ordered if word not in set(reserved)]
for start in range(0, len(rest), 300):
    reserved += need_bars(rest[start:start + 300])
reserved = sorted(set(reserved))
print(f'{len(ordered)} words tried, {len(reserved)} need bars')
print(' '.join(reserved))
if '--write' in sys.argv:
    table['reserved_words'] = reserved
    text = json.dumps(table, indent=2, ensure_ascii=False)
    text = text.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    open(language, 'w').write(text + '\n')
