#!/usr/bin/env python3
import os
import re
import datetime
import sys  # Added for potential stderr logging

# Use a raw string for the regex pattern
tag_re = re.compile(r"^(@+)(.*)$")


def file_prefix_time(path):
    """
    Generates a prefix string for the file, usually based on its name or timestamp.
    Ensures a trailing space for consistent formatting when joined later.
    """
    base = os.path.basename(path)
    prefix_text = ""
    # Check if the first 13 characters are digits for the specific timestamp format
    if len(base) >= 13 and base[0:13].isnumeric():
        year = base[0:4]
        week = base[4:6]  # Week of the year
        day = base[6:7]  # Day of the week (1-7)
        hours = base[7:9]
        minutes = base[9:11]
        seconds = base[11:13]
        prefix_text = f"{year}-{week}-{day} {hours}:{minutes}:{seconds}"
    else:
        # Fallback to filename without extension, padded
        prefix_text = f"{os.path.splitext(base)[0]:<18}"
    return prefix_text + " "  # Ensure trailing space


def to_tags(lines):
    """
    Extracts tags (lines starting with '@') from the beginning of the file content.
    Sorts tags by the number of '@' characters (e.g., '@@' before '@').
    """
    tags = []
    # Iterate through lines to find tags. Stop if lines don't start with '@'
    # or after a reasonable number of lines if no tags are found early.
    for line_num, line in enumerate(lines):
        if line_num > 20 and not line.startswith(
            "@"
        ):  # Heuristic: stop if deep and no more tags
            break

        if not line.strip():  # Skip effectively empty lines
            # If we encounter a blank line after already finding some tags,
            # or if we are past the very beginning and hit a blank line after a non-tag, consider it end of metadata.
            if tags or (line_num > 0 and not lines[line_num - 1].startswith("@")):
                break
            continue

        m = tag_re.match(line)
        if not m:
            # If it's the first line and not a tag, or if we encounter a non-tag line after tags, stop.
            if line_num == 0 or tags:
                break
            else:  # Still in potential metadata block but this line isn't a tag, continue (e.g. empty lines handled above)
                continue

        tags.append(
            {
                "num": len(m.group(1)),
                "text": m.group(
                    2
                ).strip(),  # Remove leading/trailing whitespace from tag text
            }
        )

    # Sort tags: '@@TagName' (num=2) comes before '@TagName' (num=1)
    tags.sort(key=lambda tag: tag["num"], reverse=True)

    if not tags:
        return [{"num": 0, "text": "Untitled"}]  # Default tag if none are found
    return tags


def get_zortex_metadata(path, stripped_lines):
    """
    Processes a list of (already stripped) lines from a file to extract Zortex metadata.
    Constructs the 'content' string formatted for FZF and its previewer.
    """
    tags = to_tags(stripped_lines)

    # Prepare the header string (e.g., timestamp or filename part)
    # file_prefix_time already ensures a trailing space.
    header_with_space = file_prefix_time(path)

    # These lines will be joined by " \f " for FZF.
    # The first element is the header.
    final_lines_for_join = [
        header_with_space.strip()
    ]  # Store header without its trailing space temporarily if joiner adds space.
    # Original joiner is " \f ", so "header " \f " line1" -> "header  \f  line1"
    # If header is "header_text ", and join is " \f "
    # -> "header_text  \f line1 \f line2"
    # Let's ensure file_prefix_time returns "text " and then join.
    # The original code was: lines.insert(0, file_prefix_time(path) + " ")
    # then " \f ".join(lines). This resulted in:
    # (file_prefix_time(path) + " ") + " \f " + line1 + " \f " + line2 ...
    # So, the header itself ends with a space, and it's the first element.

    # Reconstruct precisely:
    # 1. Get header string with its deliberate trailing space.
    # 2. This header string becomes the first element in a list.
    # 3. Subsequent original file lines are added to this list.
    # 4. The list is joined with " \f ".

    elements_to_join = [
        header_with_space
    ]  # header_with_space already has the trailing space.

    if path.endswith("storage.zortex"):
        # For 'storage.zortex', use header + first 2 original lines for the content payload
        elements_to_join.extend(stripped_lines[:2])
    else:
        # For other files, use header + all original lines
        elements_to_join.extend(stripped_lines)

    content = " \f ".join(elements_to_join)

    return {
        "path": path,
        "content": content,
        "tags": tags,
        "name": tags[0]["text"]
        if tags and tags[0]["text"]
        else "Untitled",  # Ensure 'name' is safe
    }


def get_path_metadata(path):
    """
    Reads a file, strips lines, and calls get_zortex_metadata to process it.
    Includes basic error handling for file operations.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            # rstrip() without args removes all trailing whitespace, including newlines.
            # rstrip('\n\r') specifically targets common newline characters.
            stripped_lines = [line.rstrip("\n\r") for line in f]
        return get_zortex_metadata(path, stripped_lines)
    except Exception as e:
        # print(f"Error processing file {path}: {e}", file=sys.stderr) # Optional: log to stderr
        # Return a consistent error structure for FZF if a file fails
        error_header = file_prefix_time(path)  # Get standard header
        return {
            "path": path,
            "content": f"{error_header.strip()} \f ERROR: Could not read/process file. ({e})",  # Ensure header, then error
            "tags": [{"num": 0, "text": "ERROR_PROCESSING_FILE"}],
            "name": "ERROR_PROCESSING_FILE",
        }


if __name__ == "__main__":
    # Example usage for testing zortex.py directly (optional)
    if len(sys.argv) > 1:
        test_file_path = sys.argv[1]
        if os.path.exists(test_file_path):
            metadata = get_path_metadata(test_file_path)
            import json

            print(json.dumps(metadata, indent=2))
        else:
            print(f"Test file not found: {test_file_path}", file=sys.stderr)
    else:
        print(
            "Usage: python zortex.py <path_to_zortex_file_for_testing>", file=sys.stderr
        )
