"""Summarize READIT_PERF JSONL files; durations are CPU scopes, not GPU time or FPS."""
import argparse
import collections
import json
import math
from pathlib import Path


def summarize(path):
    groups = collections.defaultdict(list)
    header = None
    footer = None
    invalid = 0
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            invalid += 1
            continue
        if 'kind' in event:
            header = event
        elif 'dropped' in event:
            footer = event
        elif 'duration_us' in event:
            groups[event['target'] + '::' + event['name']].append(event['duration_us'] / 1000)
    print(f'\n{path}\n{header}')
    print('CPU scope                                      count   p50 ms   p95 ms   p99 ms   max ms  >16.7ms')
    for name, values in sorted(groups.items()):
        values.sort()
        def percentile(p):
            return values[max(0, math.ceil(len(values) * p) - 1)]
        print(f'{name:46} {len(values):6} {percentile(.5):8.3f} {percentile(.95):8.3f} {percentile(.99):8.3f} {max(values):8.3f} {sum(v > 16.7 for v in values):8}')
    print(f'Completed: {footer is not None}; dropped: {footer}; incomplete/invalid lines: {invalid}')
    print('Nested scopes overlap; do not sum durations. draw/present are CPU work, not end-to-end frame latency.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    for path in parser.parse_args().files:
        summarize(path)
