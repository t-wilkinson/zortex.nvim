"""Tests for notes.py and the notes routes: python3 -m unittest app/test_notes.py"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from notes import NotesIndex, classify  # noqa: E402


def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class NotesIndexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = self.tmp.name
        write(r, "calendar.zortex", "@@Calendar\n\n2026-10-11:\n09:00 Plan\n")
        write(r, "projects.zortex", "@@Projects\n@@P\n\n# Zortex\n- [ ] Search tab\n")
        write(r, "2026-10-01.123.zortex", "@@Scratch\n\nrandom top-level note\n")
        write(r, "z/rust.zortex", "@@Rust\n@@Rustlang\n@Programming\n\n# Ownership\nborrow checker notes\n")
        write(r, "z/archive.rust.zortex", "@@Rust\n@Archive\n\nold\n")
        write(r, "z/.syncthing.rust.zortex.tmp", "@@Temp\n")
        write(r, "z/rust.sync-conflict-20261011-ABC.zortex", "@@Conflict\n")
        write(r, ".z/state.zortex", "@@Hidden\n")
        self.idx = NotesIndex(r, ttl=0)

    def tearDown(self):
        self.tmp.cleanup()

    def rels(self, **kw):
        return [n.rel for n in self.idx.notes(**kw)]

    def test_visibility(self):
        rels = self.rels()
        self.assertIn("calendar.zortex", rels)  # special
        self.assertIn("projects.zortex", rels)
        self.assertIn("z/rust.zortex", rels)
        self.assertNotIn("2026-10-01.123.zortex", rels)  # plain top-level note hidden
        self.assertFalse(any("sync" in r or r.startswith(".z") for r in rels), rels)
        self.assertIn("2026-10-01.123.zortex", self.rels(include_all=True))

    def test_tree(self):
        tree = self.idx.tree()
        self.assertEqual([n["rel"] for n in tree["notes"]], ["calendar.zortex", "projects.zortex"])
        self.assertEqual(tree["dirs"][0]["name"], "z")
        titles = [n["title"] for n in tree["dirs"][0]["notes"]]
        self.assertEqual(titles[0], "Rust")

    def test_search_names_aliases_tags_lines(self):
        res = self.idx.search("rustl")
        self.assertEqual(res["notes"][0]["rel"], "z/rust.zortex")  # alias prefix
        res = self.idx.search("rust")
        self.assertEqual(res["notes"][0]["rel"], "z/rust.zortex")  # archive sinks
        self.assertEqual(res["notes"][-1]["rel"], "z/archive.rust.zortex")
        res = self.idx.search("programming")
        self.assertEqual([n["rel"] for n in res["notes"]], ["z/rust.zortex"])
        res = self.idx.search("zortex")  # the file extension is not a match
        self.assertEqual(res["notes"], [])
        res = self.idx.search("borrow checker")
        self.assertEqual(res["lines"][0]["lnum"], 6)

    def test_read_is_confined_to_the_folder(self):
        self.assertIsNotNone(self.idx.read_lines("z/rust.zortex"))
        self.assertIsNone(self.idx.read_lines("../etc/passwd.zortex"))
        self.assertIsNone(self.idx.read_lines("z/rust.txt"))

    def test_changes_are_picked_up(self):
        write(self.tmp.name, "z/go.zortex", "@@Go\n")
        self.assertIn("z/go.zortex", self.rels())
        os.remove(os.path.join(self.tmp.name, "z/go.zortex"))
        self.assertNotIn("z/go.zortex", self.rels())

    def test_classify(self):
        kinds = [l["kind"] for l in classify(["@@A", "# H", "Label:", "- [ ] t", "- [x] d", "```", "# c", "```", "text"])]
        self.assertEqual(kinds, ["article", "heading", "label", "task", "task_done", "fence", "code", "fence", "text"])


class RoutesTest(unittest.TestCase):
    def test_routes(self):
        try:
            import flask  # noqa: F401
        except ImportError:
            self.skipTest("flask not installed")
        tmp = tempfile.TemporaryDirectory()
        write(tmp.name, "z/rust.zortex", "@@Rust\n\n# Ownership\n")
        os.environ["NOTES_DIR"] = tmp.name
        os.environ["DATABASE_PATH"] = os.path.join(tmp.name, "db", "n.db")
        import importlib
        import server

        importlib.reload(server)
        server.init_database()
        client = server.app.test_client()
        self.assertEqual(client.get("/api/notes/tree").get_json()["dirs"][0]["name"], "z")
        self.assertEqual(client.get("/api/notes/search?q=rust").get_json()["notes"][0]["title"], "Rust")
        self.assertEqual(client.get("/api/notes/file?path=z/rust.zortex").get_json()["lines"][2]["kind"], "heading")
        self.assertEqual(client.get("/api/notes/file?path=../x.zortex").status_code, 404)
        self.assertIn(b"notes-tab", client.get("/").data)
        tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
