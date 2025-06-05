import os
import re
import datetime

tag_re = re.compile("^(@+)(.*)$")  # Count tags and heading links
# file_re = re.compile("^\d+$")


def file_prefix_time(path):
    # # creation_time = os.path.getctime(path)
    # modified_time = os.path.getmtime(path)
    # dt = datetime.datetime.fromtimestamp(modified_time)
    # return dt.strftime("%Y-%m-%d %H:%M")
    base = os.path.basename(path)

    if base[0:13].isnumeric():
        year = base[0:4]
        week = base[4:6]
        day = base[6:7]
        hours = base[7:9]
        minutes = base[9:11]
        seconds = base[11:13]

        return f"{year}-{week}-{day} {hours}:{minutes}:{seconds}"
    else:
        return f"{base.replace('.zortex', ''):<18}"




def to_tags(lines):
    """
    Each article begins with metadata consisting of a number lines containing:
    `@@` for the article name or
    `@` for tags.
    """
    tags = []

    # Search for tags until the article content starts.
    for line in lines:
        if len(line) == 0:
            continue

        m = tag_re.match(line)

        if not m:
            break

        tags.append(
            {
                "num": len(m.group(1)),
                "text": m.group(2),
            }
        )

    # Put article names starting with `@@` before other tags.
    tags = sorted(tags, key=lambda tag: tag["num"], reverse=True)
    if len(tags) == 0:
        return [{"num": 0, "text": "Untitled"}]
    else:
        return tags


def get_zortex_metadata(path, lines):
    tags = to_tags(lines)

    # Prepare the file for preview
    lines.insert(0, file_prefix_time(path) + " ")

    # PERF: reading and joining the lines requires readding and adding all the files into memory. Is there a faster, memory efficient way to do this?

    # Storage.zortex is a massive long-term storage file that we don't want to search
    if path.endswith("storage.zortex"):
        # content = ' \f'.join([*lines[:1], *list(map(lambda tag: tag['text'], tags))])
        content = " \f".join(lines[:3])
    else:
        content = " \f".join(lines)

    return {"path": path, "content": content, "tags": tags, "name": tags[0]["text"]}


# PERF: reading and joining the lines requires readding and adding all the files into memory. Is there a faster, memory efficient way to do this?
def get_path_metadata(path):
    # Tried this but doesn't work
    # with open(path, "r") as f:
    #     lines = (line.rstrip() for line in f)
    #     return get_zortex_metadata(path, lines)
    lines = list(map(lambda line: line.rstrip(), open(path, "r").readlines()))
    return get_zortex_metadata(path, lines)


def get_content_metadata(file_content):
    now = str(datetime.datetime.now())
    lines = list(map(lambda line: line.rstrip(), file_content.split("\n")))
    return get_zortex_metadata(now, lines)
