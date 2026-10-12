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
        write(r, "z/papers/attention.pdf", "%PDF-1.4 fake")
        write(r, "z/img/diagram.png", "png")
        write(r, "z/readme.txt", "hello text")
        write(r, "loose.pdf", "%PDF top-level")
        write(r, "z/.hidden.pdf", "x")
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
        z = tree["dirs"][0]
        self.assertEqual(z["name"], "z")
        titles = [n["title"] for n in z["notes"]]
        self.assertEqual(titles[0], "Rust")  # notes before files
        self.assertEqual(titles[-1], "readme.txt")
        self.assertEqual([d["name"] for d in z["dirs"]], ["img", "papers"])
        pdf = z["dirs"][1]["notes"][0]
        self.assertEqual((pdf["kind"], pdf["view"], pdf["mime"]), ("file", "pdf", "application/pdf"))
        self.assertEqual(z["dirs"][0]["notes"][0]["view"], "image")

    def test_files_visibility(self):
        rels = self.rels()
        self.assertIn("z/papers/attention.pdf", rels)
        self.assertNotIn("loose.pdf", rels)  # top-level other files hidden by default
        self.assertNotIn("z/.hidden.pdf", rels)
        self.assertIn("loose.pdf", self.rels(include_all=True))
        self.assertNotIn("z/papers/attention.pdf", self.rels(files=False))

    def test_search_files(self):
        res = self.idx.search("attention")
        self.assertEqual(res["notes"][0]["rel"], "z/papers/attention.pdf")
        res = self.idx.search("pdf papers")  # extension and folder
        self.assertEqual([n["rel"] for n in res["notes"]], ["z/papers/attention.pdf"])
        self.assertEqual(self.idx.search("attention", files=False)["notes"], [])

    def test_any_file_paths_are_confined(self):
        self.assertIsNotNone(self.idx.path_for("z/papers/attention.pdf", any_file=True))
        self.assertIsNone(self.idx.path_for("z/papers/attention.pdf"))  # not a note
        for bad in ["../x.pdf", "z/../../etc/passwd", "/etc/passwd", "z/.hidden.pdf", ".z/state.zortex", "z//readme.txt"]:
            self.assertIsNone(self.idx.path_for(bad, any_file=True), bad)
        outside = tempfile.NamedTemporaryFile(suffix=".pdf", delete=False)
        outside.close()
        os.symlink(outside.name, os.path.join(self.tmp.name, "z", "escape.pdf"))
        self.assertIsNone(self.idx.path_for("z/escape.pdf", any_file=True))
        os.unlink(outside.name)

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
        write(tmp.name, "z/paper.pdf", "%PDF-1.4 " + "x" * 100)
        write(tmp.name, "z/page.svg", "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>")
        os.environ["NOTES_DIR"] = tmp.name
        dbdir = tempfile.TemporaryDirectory()  # outside the notes folder
        os.environ["DATABASE_PATH"] = os.path.join(dbdir.name, "n.db")
        import importlib
        import server

        importlib.reload(server)
        server.init_database()
        client = server.app.test_client()
        self.assertEqual(client.get("/api/notes/tree").get_json()["dirs"][0]["name"], "z")
        self.assertEqual(client.get("/api/notes/search?q=rust").get_json()["notes"][0]["title"], "Rust")
        self.assertEqual(client.get("/api/notes/file?path=z/rust.zortex").get_json()["lines"][2]["kind"], "heading")
        self.assertEqual(client.get("/api/notes/file?path=../x.zortex").status_code, 404)
        page = client.get("/").data
        self.assertNotIn(b"notes-tab", page)  # the notes UI is the web app now
        self.assertIn(b'<a href="/" aria-current="page">Calendar</a>', page)
        self.assertNotIn(b">Files</a>", page)  # no NOTES_URL: no notes tabs
        self.assertEqual(client.get("/static/style.css").status_code, 200)
        self.assertEqual(client.get("/static/server.py").status_code, 404)
        self.assertEqual(client.get("/api/summary").get_json()["status"], "ok")

        # other files: metadata, raw content with ranges, downloads, sandboxing
        info = client.get("/api/notes/file?path=z/paper.pdf").get_json()
        self.assertEqual((info["kind"], info["view"]), ("file", "pdf"))
        r = client.get("/api/notes/raw?path=z/paper.pdf")
        self.assertEqual(r.mimetype, "application/pdf")
        self.assertTrue(r.data.startswith(b"%PDF"))
        self.assertNotIn("Content-Security-Policy", r.headers)
        r = client.get("/api/notes/raw?path=z/paper.pdf", headers={"Range": "bytes=0-3"})
        self.assertEqual((r.status_code, r.data), (206, b"%PDF"))
        r = client.get("/api/notes/raw?path=z/paper.pdf&download=1")
        self.assertIn("attachment", r.headers["Content-Disposition"])
        r = client.get("/api/notes/raw?path=z/page.svg")
        self.assertEqual(r.headers["Content-Security-Policy"], "sandbox")
        self.assertEqual(client.get("/api/notes/raw?path=../etc/passwd").status_code, 404)
        r = client.get("/api/notes/raw?path=z/rust.zortex")
        self.assertTrue(r.content_type.startswith("text/plain"))
        tmp.cleanup()
        dbdir.cleanup()

    def test_shared_nav(self):
        try:
            import flask  # noqa: F401
        except ImportError:
            self.skipTest("flask not installed")
        dbdir = tempfile.TemporaryDirectory()
        os.environ["DATABASE_PATH"] = os.path.join(dbdir.name, "n.db")
        os.environ["NOTES_URL"] = "/notes"
        import importlib
        import server

        try:
            importlib.reload(server)
            server.init_database()
            page = server.app.test_client().get("/").data
            for link in (b'href="/notes/f/">Files', b'href="/notes/tags">Tags', b'href="/notes/broken">Broken',
                         b'action="/notes/search"', b'class="brand" href="/notes/"'):
                self.assertIn(link, page)
        finally:
            del os.environ["NOTES_URL"]
            dbdir.cleanup()


if __name__ == "__main__":
    unittest.main()
