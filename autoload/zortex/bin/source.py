#!/usr/bin/env python3
import os
import glob
import sys
import re
from multiprocessing import Pool
import argparse
from zettel import source_zettels, path_to_zettel


def from_zettel(zettel):
    return zettel['file']


def zortex_sort_key(zettel):
    text = zettel['tags'][0]['text']

    # @@[name](link)
    #   ^ sort these last
    return (text[0] in '[' if len(text) >= 1 else False, text.lower(), len(zettel['tags']))


def filter_num_tags(zettel, max_tags=1):
    return len(zettel['tags']) <= max_tags


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('dir')
    parser.add_argument('ext', nargs='?', default='zortex')
    parser.add_argument('-t', '--type')
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()

    zortex_dir = args.dir
    zortex_ext = args.ext

    if args.test == True:
        zettels = source_zettels()
    else:
        with Pool() as p:
            files = glob.glob(os.path.join(zortex_dir, '*.zortex'))
            zettels = p.map(path_to_zettel, files)

    # Only show zettels with a single master tag
    if args.type == 'single-tag':
        zettels = filter(filter_num_tags, zettels)

    sorted_zettels = sorted(zettels, key=zortex_sort_key, reverse=True)

    # Only show a single zettel per master tag
    if args.type == 'unique':
        unique_zettels = {}
        for zettel in sorted_zettels:
            tag = zettel['tags'][0]['text']
            unique_zettels[tag] = zettel
        sorted_zettels = unique_zettels.values()

    files = map(from_zettel, sorted_zettels)
    print('\n'.join(files))
