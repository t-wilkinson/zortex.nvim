"""Read-only access to a (synced) zortex notes folder: index, tree, search.

Standard library only, so the server stays small. The index is rebuilt
lazily: a file is re-read only when its mtime or size changes, and the folder
is re-scanned at most every `ttl` seconds.

Which notes are shown
---------------------
- every ``*.zortex`` file in a subfolder (``z/...``),
- top-level ``*.zortex`` files only when they are *special*
  (``NOTES_SPECIAL``, default: calendar, structure, projects, areas, okr),
  unless ``include_all`` is requested,
- never hidden folders (``.z``, ``.git``, ``.stversions``, ``.stfolder``) or
  Syncthing artefacts (``.syncthing.*.tmp``, ``*.sync-conflict-*``).
"""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field

DEFAULT_SPECIAL = ("calendar", "structure", "projects", "areas", "okr")


@dataclass
class Note:
    rel: str  # path relative to the notes folder, "/"-separated
    names: list[str] = field(default_factory=list)  # @@ article names
    tags: list[str] = field(default_factory=list)  # @ tags
    mtime: float = 0.0
    size: int = 0
    top_level: bool = False
    special: bool = False

    @property
    def title(self) -> str:
        return self.names[0] if self.names else os.path.splitext(os.path.basename(self.rel))[0]

    @property
    def archived(self) -> bool:
        base = os.path.basename(self.rel)
        return base.startswith("archive.") or any(t.lower() == "archive" for t in self.tags)

    def summary(self) -> dict:
        return {
            "rel": self.rel,
            "title": self.title,
            "names": self.names,
            "tags": self.tags,
            "mtime": self.mtime,
            "archived": self.archived,
            "special": self.special,
        }


def read_header(path: str, max_lines: int = 50) -> tuple[list[str], list[str]]:
    """Article names and tags from a note's header block."""
    names: list[str] = []
    tags: list[str] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                line = line.rstrip("\n")
                if line.startswith("@@"):
                    names.append(line[2:].strip())
                elif re.match(r"^@\w", line):
                    tags.append(line[1:].strip())
                elif line.strip():
                    break
    except OSError:
        pass
    return names, tags


def is_sync_artifact(name: str) -> bool:
    return name.startswith(".syncthing.") or ".sync-conflict-" in name or name.endswith(".tmp")


class NotesIndex:
    def __init__(self, root: str, extension: str = ".zortex", special=DEFAULT_SPECIAL, ttl: float = 2.0):
        self.root = os.path.abspath(os.path.expanduser(root))
        self.extension = extension
        self.special = {s.strip().lower() for s in special if s.strip()}
        self.ttl = ttl
        self._notes: dict[str, Note] = {}
        self._scanned_at = 0.0

    # ------------------------------------------------------------------ scan
    def _scan(self) -> None:
        seen = set()
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            rel_dir = os.path.relpath(dirpath, self.root)
            rel_dir = "" if rel_dir == "." else rel_dir.replace(os.sep, "/")
            for name in filenames:
                if not name.endswith(self.extension) or name.startswith(".") or is_sync_artifact(name):
                    continue
                rel = f"{rel_dir}/{name}" if rel_dir else name
                path = os.path.join(dirpath, name)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                seen.add(rel)
                note = self._notes.get(rel)
                if note is None or note.mtime != st.st_mtime or note.size != st.st_size:
                    names, tags = read_header(path)
                    stem = name[: -len(self.extension)].lower()
                    note = Note(
                        rel=rel,
                        names=names,
                        tags=tags,
                        mtime=st.st_mtime,
                        size=st.st_size,
                        top_level=not rel_dir,
                        special=not rel_dir and stem in self.special,
                    )
                    self._notes[rel] = note
        for rel in list(self._notes):
            if rel not in seen:
                del self._notes[rel]
        self._scanned_at = time.monotonic()

    def notes(self, include_all: bool = False) -> list[Note]:
        if time.monotonic() - self._scanned_at > self.ttl:
            self._scan()
        out = [n for n in self._notes.values() if include_all or not n.top_level or n.special]
        # special notes first, then folders' notes by path
        return sorted(out, key=lambda n: (not n.special, n.rel.count("/") == 0, n.rel.lower()))

    # ------------------------------------------------------------------ tree
    def tree(self, include_all: bool = False) -> dict:
        root = {"name": "", "rel": "", "dirs": [], "notes": []}
        folders = {"": root}

        def folder(rel: str) -> dict:
            if rel in folders:
                return folders[rel]
            parent, _, name = rel.rpartition("/")
            node = {"name": name, "rel": rel, "dirs": [], "notes": []}
            folders[rel] = node
            folder(parent)["dirs"].append(node)
            return node

        for note in self.notes(include_all):
            parent = note.rel.rpartition("/")[0]
            folder(parent)["notes"].append(note.summary())

        def sort(node: dict) -> None:
            node["dirs"].sort(key=lambda d: d["name"].lower())
            node["notes"].sort(key=lambda n: (not n["special"], n["title"].lower()))
            for d in node["dirs"]:
                sort(d)

        sort(root)
        return root

    # ---------------------------------------------------------------- search
    @staticmethod
    def _word_score(word: str, text: str) -> int:
        """Like the plugin: exact 3, prefix 2, substring 1."""
        if text == word:
            return 3
        if text.startswith(word):
            return 2
        if word in text:
            return 1
        return 0

    def search(self, query: str, include_all: bool = False, limit: int = 50, lines: bool = True) -> dict:
        """Notes whose name, alias, tag or path matches every word, best first;
        then lines containing every word (when `lines`)."""
        words = [w.lower() for w in query.split() if w.strip()]
        notes = self.notes(include_all)
        if not words:
            return {"notes": [n.summary() for n in notes[:limit]], "lines": []}

        scored = []
        for note in notes:
            fields = [n.lower() for n in note.names] + [t.lower() for t in note.tags]
            stem = note.rel[: -len(self.extension)].lower()  # the extension matches everything
            fields.append(stem)
            fields.append(stem.rpartition("/")[2])
            total = 0
            for w in words:
                best = max((self._word_score(w, f) for f in fields), default=0)
                if best == 0:
                    total = -1
                    break
                total += best
            if total > 0:
                # names matter more than paths; archived notes sink
                name_hit = any(f.startswith(words[0]) for f in fields[: len(note.names)])
                scored.append((total + (2 if name_hit else 0) - (3 if note.archived else 0), note))
        scored.sort(key=lambda s: (-s[0], s[1].rel.lower()))
        result_notes = [dict(n.summary(), score=s) for s, n in scored[:limit]]

        result_lines = []
        if lines and sum(len(w) for w in words) >= 3:
            for note in notes:
                if len(result_lines) >= limit:
                    break
                for lnum, text in enumerate(self.read_lines(note.rel) or [], start=1):
                    low = text.lower()
                    if all(w in low for w in words):
                        result_lines.append({"rel": note.rel, "title": note.title, "lnum": lnum, "text": text.strip()})
                        if len(result_lines) >= limit:
                            break
        return {"notes": result_notes, "lines": result_lines}

    # ------------------------------------------------------------------ read
    def path_for(self, rel: str) -> str | None:
        """Absolute path of a note inside the folder, or None (no escaping the root)."""
        if not rel or not rel.endswith(self.extension):
            return None
        path = os.path.abspath(os.path.join(self.root, rel))
        if not path.startswith(self.root + os.sep) or not os.path.isfile(path):
            return None
        return path

    def read_lines(self, rel: str) -> list[str] | None:
        path = self.path_for(rel)
        if not path:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()


# ---------------------------------------------------------------------------
# Minimal line classification for the viewer (the full grammar lives in the
# plugin's core/syntax.lua; the Go app will port it with the AST fixtures).
# ---------------------------------------------------------------------------

_LINE_KINDS = [
    ("article", re.compile(r"^@@")),
    ("tag", re.compile(r"^@\w")),
    ("heading", re.compile(r"^(#{1,6})\s+\S")),
    ("bold_heading", re.compile(r"^\*\*[^*]+\*\*:?\s*$")),
    ("task_done", re.compile(r"^\s*-\s*\[[xX]\]\s+\S")),
    ("task", re.compile(r"^\s*-\s*\[.\]\s+\S")),
    ("label", re.compile(r"^[^:]+:$")),
    ("item", re.compile(r"^\s*([-+*]|\d+\.|\d{1,2}:\d{2})\s")),
    ("table", re.compile(r"^\s*\|.*\|")),
    ("quote", re.compile(r"^\s*(\||>\s)")),
]


def classify(lines: list[str]) -> list[dict]:
    out = []
    in_code = False
    for line in lines:
        if re.match(r"^\s*(```|~~~)", line):
            in_code = not in_code
            out.append({"kind": "fence", "text": line})
            continue
        if in_code:
            out.append({"kind": "code", "text": line})
            continue
        kind = "blank" if not line.strip() else "text"
        level = None
        for name, pattern in _LINE_KINDS:
            m = pattern.match(line)
            if m:
                kind = name
                if name == "heading":
                    level = len(m.group(1))
                break
        if kind == "label" and ". " in line:
            kind = "text"
        out.append({"kind": kind, "level": level, "text": line})
    return out
