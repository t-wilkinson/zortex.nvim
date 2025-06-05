#!/usr/bin/env python3
import os
import glob
from concurrent.futures import ProcessPoolExecutor
import argparse
from zortex import get_path_metadata


def metadata_sort_key(metadata):
    text = metadata["tags"][0]["text"]

    return (
        text.lower(),
        len(metadata["tags"]),
    )


def filter_num_tags(metadata, max_tags=1):
    return len(metadata["tags"]) <= max_tags


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dir")
    parser.add_argument("ext", nargs="?", default="zortex")
    parser.add_argument("-t", "--type")
    args = parser.parse_args()

    zortex_dir = args.dir
    zortex_ext = args.ext

    num_workers = os.cpu_count() or 1

    files_to_process = glob.glob(os.path.join(zortex_dir, "*.zortex"))

    # Process files in chunks to avoid creating a process per file.
    if len(files_to_process) > 0:
        heuristic = 8
        chunk_size = max(1,
            (len(files_to_process) + num_workers * heuristic - 1)
            // (num_workers * heuristic)
                    )
    else:
        chunk_size = 1

    print(f"Using {num_workers} workers and chunksize {chunk_size}.")

    with ProcessPoolExecutor(max_workers=num_workers) as executor:
        results_iterator = executor.map(get_path_metadata, files_to_process, chunksize=chunk_size)
        zortex_metadata = list(results_iterator)

    # Only show zortexs with an article_name
    if args.type == "single-tag":
        # The idea here is you might want some articles without a name but multiple tags.
        # The idea would be to explore the connections between ideas.
        # I'm not sure it's that useful though.
        zortex_metadata = filter(filter_num_tags, zortex_metadata)

    zortex_metadata = sorted(zortex_metadata, key=metadata_sort_key, reverse=True)

    # Show unique article names
    if args.type == "unique":
        # The idea is you might want to differentiate articles based on their zortex_metadata (for example different types of tags).
        # I don't think it's that useful but I'll keep it for now.
        unique_articles = {}
        for metadata in zortex_metadata:
            tag = metadata["tags"][0]["text"]
            unique_articles[tag] = metadata
        zortex_metadata = unique_articles.values()

    files = map(lambda metadata: metadata["content"], zortex_metadata)
    print("\n".join(files))
