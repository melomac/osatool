"""
Finds the words that the compiler does not give back, among those a
script can use outside a `tell` block: the words of the language table
and of Standard Additions.

    python3 Scripts/compiler-words.py Terminology/language.json \\
        Terminology/applications.json <work folder> .build/debug/osatool [--write]

The language table comes from the terminology of the system, which still
lists words of old suites: `ADB address`, `row`, `USB`. The compiler
refuses some of them, and reads others as the name of a variable. A few
words of Standard Additions are hidden by a word of the language:
`properties` is read as `every property`. The tool must not print such
a word: its text would not compile back to the same script.

Every class, property and enumerator is written in small scripts of
ours, one word on each line, with no `tell` block:

    set t12 to <word>                 as a value
    set t12 to 1 as <word>            as a type            (not an enumerator)
    set t12 to every <word> of x      as a class of items  (not an enumerator)

The scripts are compiled, never run. Lines the compiler refuses are
taken out one by one. The listing of the tool then shows what each word
was compiled to, and a word is kept only when one of the forms gives its
own code back:

    a class or a property      the code as a class               string
                               the code as a property of `it`    name
                               the code as a global property     pi
                               the code as a type                1 as styled text
                               the code as a class of items      every item of x
    an enumerator              the code as a constant of 8 bytes yes
                               `true` and `false`, which have their own
                               instructions and are stored as the
                               constants `boovtrue` and `boovfals`

With --write, the words that are not kept are taken out of the two
files. The file of applications is written by the tool itself, so it
keeps its layout. Run Scripts/embed-terminology.sh after it.

Scripts/update-terminology.sh reads the words of Standard Additions
again from the system: run this script after it.

It calls osacompile, so it works only with OSATOOL_APPLE_TOOLS set,
like the tests that call Apple's tools.
"""
import json
import os
import re
import subprocess
import sys

if not os.environ.get('OSATOOL_APPLE_TOOLS'):
    sys.exit('compiler-words.py: set OSATOOL_APPLE_TOOLS=1 to let osacompile run')

language_path, store_path, work = sys.argv[1:4]
tool = os.path.abspath(sys.argv[4])
language = json.load(open(language_path, encoding='utf-8'))
store = json.load(open(store_path, encoding='utf-8'))
additions = next(d for d in store['dictionaries'] if d['name'] == 'StandardAdditions')
os.makedirs(work, exist_ok=True)
# Dates and numbers are compiled the same way on every Mac with these two
# arguments. osacompile takes them as files to compile too, so they exist.
for name in ('-AppleLocale', 'en_US_POSIX'):
    open(os.path.join(work, name), 'w').close()

# Each item: where it is from, its kind, its four-letter code, its name.
items = [('language', 'term', term['code'], term['name']) for term in language['terms']]
items += [('language', 'enumerator', term['code'], term['name']) for term in language['enumerations']]
items += [('Standard Additions', 'term', term['code'], term['name']) for term in additions.get('terms', [])]
items += [('Standard Additions', 'enumerator', term['code'][4:], term['name']) for term in additions.get('constants', [])]


def compiled(form, only=None):
    """
    Compiles one line `set tN to <form with the word>` for each item
    (of the kind `only`, when given). Returns what each line pushes
    before its `set`, as a list of (first byte, instruction, constant),
    and the answer of the compiler for each line it refuses.
    """
    lines = {'t%d' % index: 'set t%d to %s' % (index, form % item[3])
             for index, item in enumerate(items) if only in (None, item[1])}
    refused = {}
    while True:
        order = list(lines)
        with open(os.path.join(work, 'words.applescript'), 'w', encoding='utf-8') as source:
            source.write('\n'.join(lines[key] for key in order) + '\n')
        done = subprocess.run(['osacompile', '-x', '-o', 'words.scpt', 'words.applescript', '-AppleLocale', 'en_US_POSIX'],
                              capture_output=True, text=True, cwd=work)
        if done.returncode == 0:
            break
        found = re.search(r'words\.applescript:(\d+):', done.stderr)
        if not found or not order:
            sys.exit('compiler-words.py: osacompile: ' + done.stderr.strip()[:300])
        key = order[min(int(found.group(1)) - 1, len(order) - 1)]
        refused[key] = done.stderr.strip().split('error: ')[-1]
        del lines[key]
    listing = subprocess.run([tool, 'disassemble', 'words.scpt'], capture_output=True, text=True, cwd=work)
    if listing.returncode != 0:
        sys.exit('compiler-words.py: ' + listing.stderr.strip()[:300])
    pushed, steps = {}, []
    for line in listing.stdout.split('\n'):
        found = re.match(r'\s+[0-9a-f]+\s+([0-9a-f]+)\s+(\w+)\s*(.*)$', line)
        if not found:
            continue
        code, name, rest = found.groups()
        target = re.search(r'; "(t\d+)"', rest)
        if name.startswith('PopGlobal') and target:
            pushed[target.group(1)] = steps
            steps = []
        elif name not in ('GetData', 'StoreResult'):
            constant = re.search(r'; constant\(0x([0-9a-f]+)\)', rest)
            steps.append((code[:2], name, constant.group(1) if constant else None))
    return pushed, refused


def stored(value):
    """The code of a constant of the listing: four letters, or eight."""
    number = int(value, 16)
    return number.to_bytes(8 if number > 0xffffffff else 4, 'big').decode('mac_roman')


def as_value(steps):
    """What `set t to <word>` pushed: (what it is, its code)."""
    if len(steps) == 1 and steps[0][2] and steps[0][1].startswith('PushLiteral'):
        code = stored(steps[0][2])
        return ('an enumerator' if len(code) == 8 else 'a class'), code
    if len(steps) == 1 and steps[0][1] in ('PushTrue', 'PushFalse'):
        return 'an enumerator', 'boovtrue' if steps[0][1] == 'PushTrue' else 'boovfals'
    if len(steps) == 1 and steps[0][2] and steps[0][1].startswith('PushGlobal'):
        return 'a global property', stored(steps[0][2])
    if len(steps) == 1 and steps[0][1].startswith('PushGlobal'):
        return 'a variable', None
    if len(steps) == 3 and steps[0][1] == 'PushIt' and steps[1][2] and steps[2][0] == '2c':
        return 'a property of it', stored(steps[1][2])
    if len(steps) == 3 and steps[0][1] == 'PushIt' and steps[1][2] and steps[2][0] == '2d':
        return 'every item of a class', stored(steps[1][2])
    return 'something else', None


def as_type(steps):
    """What `set t to 1 as <word>` pushed."""
    if len(steps) == 3 and steps[1][2] and steps[1][1].startswith('PushLiteral') and steps[2][1] == 'Coerce':
        return 'a type', stored(steps[1][2])
    return 'something else', None


def as_class(steps):
    """What `set t to every <word> of x` pushed."""
    if len(steps) == 3 and steps[1][2] and steps[1][1].startswith('PushLiteral') and steps[2][0] == '2d':
        return 'a class of items', stored(steps[1][2])
    return 'something else', None


forms = [('%s', None, as_value), ('1 as %s', 'term', as_type), ('every %s of x', 'term', as_class)]
runs = [(read,) + compiled(form, only) for form, only, read in forms]

dropped = []
reasons = {}
for index, item in enumerate(items):
    origin, kind, code, name = item
    key = 't%d' % index
    wanted = ('an enumerator',) if kind == 'enumerator' else ('a class', 'a global property', 'a property of it', 'a type', 'a class of items')
    kept, first = False, None
    for read, pushed, refused in runs:
        if key in refused:
            why = 'the compiler refuses it'
        elif key not in pushed:
            continue
        else:
            what, found = read(pushed[key])
            kept = kept or (what in wanted and found is not None and found[-4:] == code)
            why = 'it is compiled to ' + what
            if found is not None and found[-4:] != code:
                why += ', with another code'
        first = first or why
    if not kept:
        dropped.append(item)
        reasons.setdefault((origin, kind, first), []).append('%s %r' % (name, code))

for (origin, kind, why), names in sorted(reasons.items()):
    print('%4d  %-18s %-10s as a value, %s' % (len(names), origin, kind, why))
    print('          ' + '; '.join(names))
for origin in ('language', 'Standard Additions'):
    for kind in ('term', 'enumerator'):
        total = sum(1 for item in items if item[:2] == (origin, kind))
        gone = sum(1 for item in dropped if item[:2] == (origin, kind))
        print('%s, %ss: %d in the file, %d kept, %d not kept' % (origin, kind, total, total - gone, gone))

if '--write' in sys.argv:
    def gone(origin, kind, code, name):
        return (origin, kind, code, name) in dropped

    language['terms'] = [t for t in language['terms'] if not gone('language', 'term', t['code'], t['name'])]
    language['enumerations'] = [t for t in language['enumerations'] if not gone('language', 'enumerator', t['code'], t['name'])]
    # The same layout as Scripts/reserved-words.py writes.
    text = json.dumps(language, indent=2, ensure_ascii=False)
    text = text.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    with open(language_path, 'w', encoding='utf-8') as out:
        out.write(text + '\n')
    print('written:', language_path)

    origin = 'Standard Additions'
    additions['terms'] = [t for t in additions.get('terms', []) if not gone(origin, 'term', t['code'], t['name'])]
    additions['constants'] = [t for t in additions.get('constants', []) if not gone(origin, 'enumerator', t['code'][4:], t['name'])]
    # An enumerator is also listed without its group: it stays while a constant still has its name.
    left = {(t['code'][4:], t['name']) for t in additions['constants']}
    additions['enumerators'] = [t for t in additions.get('enumerators', [])
                                if (t['code'], t['name']) in left or not gone(origin, 'enumerator', t['code'], t['name'])]
    # A class that has no name any more has no plural name.
    named = {t['code'] for t in additions['terms']}
    additions['plurals'] = [t for t in additions.get('plurals', []) if t['code'] in named]
    edited = os.path.join(work, 'applications.json')
    with open(edited, 'w', encoding='utf-8') as out:
        json.dump(store, out, ensure_ascii=False)
    done = subprocess.run([tool, 'learn', '--output', os.path.abspath(store_path), edited], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit('compiler-words.py: ' + done.stderr.strip()[:300])
    print('written:', store_path)
