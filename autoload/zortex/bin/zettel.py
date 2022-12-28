import os
import re
import datetime

tag_re = re.compile('^(@+)(.*)$')  # Count tags and heading links
file_re = re.compile('^\d+$')

def file_creation(path):
    base = os.path.basename(path)

    if base[0:13].isnumeric():
        year = base[0:4]
        week = base[4:6]
        day = base[6:7]
        hours = base[7:9]
        minutes = base[9:11]
        seconds = base[11:13]

        return f'{year}-{week}-{day} {hours}:{minutes}:{seconds}'
    else:
        return f'{base.replace(".zortex", ""):<18}'

def to_tags(lines):
    tags = []
    for line in lines:
        if len(line) == 0:
            continue

        m = tag_re.match(line)

        if not m:
            break
        else:
            tags.append({
                "num": len(m.group(1)),
                "text": m.group(2),
            })

    tags = sorted(tags, key=lambda tag: tag['num'], reverse=True)
    if len(tags) == 0:
        return [ { "num": 0, "text": "Untitled" } ]
    else:
        return tags


def to_zettel(path, lines):
    tags = to_tags(lines)

    # Prepare the file for preview
    lines.insert(0, file_creation(path) + ' ')
    if path.endswith('storage.zortex'):
        # file = ' \f'.join([*lines[:1], *list(map(lambda tag: tag['text'], tags))])
        file = ' \f'.join(lines[:3])
    else:
        file = ' \f'.join(lines)

    return {
        'path': path,
        'file': file,
        'tags': tags,
        'name': tags[0]['text']
    }


def path_to_zettel(path):
    lines = list(map(lambda line: line.rstrip(), open(path, 'r').readlines()))
    return to_zettel(path, lines)

def file_to_zettel(file):
    now = str(datetime.datetime.now())
    lines = list(map(lambda line: line.rstrip(), file.split('\n')))
    return to_zettel(now, lines)


def source_zettels():
    files = [
"""@@One
@Tag1
@Tag2

- Context
    - Thought 1
    - Thought 2
    - Thought 3
""",
"""@@Two
@Tag1
@Tag3

- Context
    - Thought 1
    - Thought 3
""",
"""@@Three
@Tag2

- Context 2
    - Thought 2
    - Thought 3
"""
]
    return map(file_to_zettel, files)


def build_tree(zettels, tree):
    """
    Index zettels by name
    For each line in tree (nested list):
        If line is a zettel, attach that
        Otherwise, find line within current zettel
    """
    index = index_zettels(zettels)
    def _build_tree():
        for branch in tree:
            pass


def index_zettels(zettels):
    return { index[zettel['name']]: zettel for zettel in zettels }
