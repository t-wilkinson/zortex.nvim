# Legacy app

The original Next.js / Node app (markdown preview over a Neovim RPC
connection, wiki pages, 3D word trees). It is no longer maintained.

Its successor is [`../app`](../app): a small server (Flask + SQLite today, a
Go service later, see [doc/Wishlist.md](../doc/Wishlist.md)) with the
notification API, the calendar dashboard and note browsing/search. The Vim
scripts in `autoload/zortex/` that start this app's server still point here.
