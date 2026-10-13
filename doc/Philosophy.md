# Philosophy

Why zortex is a personal wiki rather than a Zettelkasten, in the author's words.

## Why it looks like this

Originally I had set to replicate the zettelkasten technique more closely, where each line was a different thought with a unique id and various tags. You could then query thoughts with certain tags. Although conceptually very interesting, I didn't actually find it useful. It allowed a purely flat layout of all my thoughts. However it had a few flaws:

- It was complicated.
- I was never encouraged to actually think and integrate my thoughts into something more meaningful as I would rely on the tag system to organize my notes.
- It discouraged thinking deeply about concepts.
- By design, it lacks a single source of truth for concepts.

I found this new system better:

- Have a couple _core_ files:
  - **Structure:** is the most important. It is a single file that links to all my other notes. Using Vim's folding, you can get an overview of the main domains of your Wikipedia, or dive down. You can put the same article in multiple locations. This allows you to continue a graph-like knowledge base, while attaching a lot of information, depth, and thought into each thought.
  - **Storage:** this is a collection of all my old files/thoughts that it will not search through. Good for stuff I will probably never need again, but keep there just in case.
  - **Inbox:** a file that somewhat matches the original zettelkasten. Each 'unique' id is the line number. You can add tags to each line.
- Prefix lines with tags such as `- #one#two# This is my line text.` Provides a natural, intuitive way to organize thoughts that can still be easily searched.
- To still express the graph knowledge that the zettelkasten provides, I've found a hybrid approach of within your articles, add subheadings that refer to or connect ideas to other articles. Which is exactly what Wikipedia does.

However this is not how I think. Over time, I found my use case of a note system closely mirrored a personal Wikipedia. I would have 10s-100s of articles that I could quickly search.

## The name

- Zettelkasten (german for note "zettel" desk "kasten") was a note taking system popularized by Niklas Luhmann, a very prolific sociologist.
- Cortex, latin for bark. It's found in the word "neocortex" and "cerebral cortex". The neocortex is a key component in cognition. The Zortex is meant to be a sort of second brain.
