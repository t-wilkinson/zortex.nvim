#!/usr/bin/env python3
import os
import glob
from concurrent.futures import ProcessPoolExecutor
import argparse
import sys  # Import sys for stderr
from zortex import (
    get_path_metadata,
)  # Assuming zortex.py is in PYTHONPATH or same directory


def metadata_sort_key(metadata):
    """
    Key function for sorting Zortex notes.
    Sorts primarily by the main tag text (case-insensitive),
    and secondarily by the number of tags.
    """
    main_tag_text = "untitled"
    num_tags = 0
    if metadata and "tags" in metadata and metadata["tags"]:
        first_tag = metadata["tags"][0]
        if "text" in first_tag:
            main_tag_text = first_tag["text"]
        num_tags = len(metadata["tags"])
    return (main_tag_text.lower(), num_tags)


def filter_num_tags(metadata, max_tags=1):
    """
    Filters metadata to include only notes with up to 'max_tags'.
    """
    return "tags" in metadata and len(metadata["tags"]) <= max_tags


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Processes Zortex notes and outputs them for FZF."
    )
    parser.add_argument("dir", help="Directory containing Zortex notes.")
    parser.add_argument(
        "ext",
        nargs="?",
        default="zortex",
        help="File extension for Zortex notes (default: zortex).",
    )
    parser.add_argument(
        "-t", "--type", help="Optional filter type (e.g., 'single-tag', 'unique')."
    )
    args = parser.parse_args()

    zortex_dir = args.dir
    zortex_ext = args.ext

    num_workers = os.cpu_count() or 1

    file_pattern = os.path.join(zortex_dir, f"*{zortex_ext}")
    files_to_process = glob.glob(file_pattern)

    if not files_to_process:
        print(zortex_dir, zortex_ext, file_pattern, file=sys.stderr)
        print(
            f"Debug: No files found matching pattern '{file_pattern}'. Check directory and extension.",
            file=sys.stderr,
        )
        sys.exit(0)

    initial_file_count = len(files_to_process)
    print(f"Debug: Found {initial_file_count} files to process.", file=sys.stderr)

    heuristic_factor = 8
    chunk_size = max(
        1,
        (initial_file_count + num_workers * heuristic_factor - 1)
        // (num_workers * heuristic_factor),
    )

    print(
        f"Debug: Processing with {num_workers} workers (chunksize: {chunk_size}).",
        file=sys.stderr,
    )

    processed_metadata = []
    with ProcessPoolExecutor(max_workers=num_workers) as executor:
        results_iterator = executor.map(
            get_path_metadata, files_to_process, chunksize=chunk_size
        )
        processed_metadata = list(results_iterator)

    print(
        f"Debug: Initially processed {len(processed_metadata)} items.", file=sys.stderr
    )

    # Make a copy for filtering if a type is specified
    final_metadata_list = list(processed_metadata)  # Work with a copy

    if args.type:
        print(f"Debug: Filtering with type: {args.type}", file=sys.stderr)
        if args.type == "single-tag":
            final_metadata_list = list(filter(filter_num_tags, final_metadata_list))
            print(
                f"Debug: After 'single-tag' filter, {len(final_metadata_list)} items remaining.",
                file=sys.stderr,
            )
        elif args.type == "unique":
            unique_articles = {}
            for item in final_metadata_list:
                if item and "tags" in item and item["tags"]:
                    primary_tag_text = item["tags"][0].get("text", "").lower()
                    if (
                        primary_tag_text and primary_tag_text not in unique_articles
                    ):  # Ensure tag is not empty
                        unique_articles[primary_tag_text] = item
            final_metadata_list = list(unique_articles.values())
            print(
                f"Debug: After 'unique' filter, {len(final_metadata_list)} items remaining.",
                file=sys.stderr,
            )
        else:
            print(
                f"Debug: Unknown filter type '{args.type}'. No filtering applied for type.",
                file=sys.stderr,
            )

    if not final_metadata_list:
        print(
            f"Debug: No metadata items remaining after potential filtering. Check filter logic or source data.",
            file=sys.stderr,
        )
    else:
        final_metadata_list.sort(key=metadata_sort_key, reverse=True)
        print(f"Debug: Sorted {len(final_metadata_list)} items.", file=sys.stderr)

    output_contents = [
        item.get("content", "")
        for item in final_metadata_list
        if item and item.get("content")
    ]

    if not output_contents:
        print(
            f"Debug: No content to display to FZF after processing and filtering. Initial files: {initial_file_count}, Processed items: {len(processed_metadata)}, Items after filter/sort: {len(final_metadata_list)}.",
            file=sys.stderr,
        )
        # Outputting at least a newline so FZF gets some input and closes, rather than hanging.
        # An empty print() sends a newline.
        print("")
    else:
        print(f"Debug: Sending {len(output_contents)} items to FZF.", file=sys.stderr)
        print("\n".join(output_contents))
