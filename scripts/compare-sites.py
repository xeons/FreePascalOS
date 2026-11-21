#!/usr/bin/env python3
# FreePascalOS
# Copyright (C) 2026 Brandon Scott
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""Real-site comparison of the web engine against a reference browser.

For each page in scripts/compare-sites.list (NAME URL per line) it
renders the page with build/tools/webbrowse (the engine on the host over
the network) and with headless Firefox (over Marionette, given a few
seconds after the load to settle) at the same viewport sizes,
scores how different the two pictures look (grayscale, per 16 px block:
the difference of the block means and of their contrast, 0 = alike,
100 = nothing alike), and drives the page in webbrowse like a user:
scrolling down to the bottom and back, hovering links and buttons,
dragging a text selection, typing into the first search box and
following a few same-site links and coming back. Crashes, hangs (the
watchdog), time-outs and engine exceptions fail the smoke test.

Everything goes into a scratch folder outside the repository (never
commit what it fetches): the PNGs, a heat map of the difference per
page, results.json and report.html / report.txt sorted by score.

    scripts/compare-sites.py [--out DIR] [--only NAME,...] [--jobs N]
        [--sizes 1280x800,400x800] [--no-smoke] [--no-render]
        [--refresh-reference] [--baseline OLD/results.json] [--webbrowse BINARY]

The reference pictures are kept between runs (--refresh-reference makes
them again) so runs before and after a change compare against the same
pictures; --baseline adds the old scores to the report.
"""

import argparse
import concurrent.futures
import html
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

from PIL import Image, ImageChops, ImageOps

sys.dont_write_bytecode = True
from firefox_reference import ReferenceBrowser  # noqa: E402 (next to this script)

REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEBBROWSE = os.path.join(REPOSITORY, 'build', 'tools', 'webbrowse')
FONTS = os.path.join(REPOSITORY, 'userland', 'fonts')
DEFAULT_LIST = os.path.join(REPOSITORY, 'scripts', 'compare-sites.list')
DEFAULT_OUT = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'compare-sites')

BLOCK = 16
RENDER_TIMEOUT = 45
SMOKE_TIMEOUT = 240
WATCHDOG_GRACE = 90

# Words in the engine's output that mean the engine itself failed (not
# the page's script).
ENGINE_FAILURES = re.compile(r'Access violation|Range check error|Runtime error|EAccessViolation|ERangeError|'
                             r'Internal error|Invalid pointer|Heap corruption|An unhandled exception|'
                             r'EInvalidCast|EIntOverflow|Stack overflow')

# A request in webbrowse's network log: start, head, took, status,
# protocol, destination, bytes, outcome, URL.
NETWORK_LINE = re.compile(r'^\s*\d+\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+\d+\s+(.*)$')

# Marks what the smoke test touches: hover targets (visible links,
# buttons, menu items), same-site links to follow and the first search
# box; returns how many it found.
MARK_SCRIPT = (
    "(function(){var host=location.hostname.replace(/^www\\./,''),hover=0,links=0;"
    "document.querySelectorAll('[data-smoke-hover],[data-smoke-link],[data-smoke-search]').forEach(function(e){"
    "e.removeAttribute('data-smoke-hover');e.removeAttribute('data-smoke-link');e.removeAttribute('data-smoke-search')});"
    "var all=document.querySelectorAll('a[href],button,[role=button],[role=menuitem],nav li,summary');"
    "for(var i=0;i<all.length&&hover<6;i++){var r=all[i].getBoundingClientRect();"
    "if(r.width>0&&r.height>0&&r.top<innerHeight*2)all[i].setAttribute('data-smoke-hover',hover++)}"
    "var anchors=document.querySelectorAll('a[href]');"
    "for(var i=0;i<anchors.length&&links<3;i++){var a=anchors[i],u;"
    "try{u=new URL(a.getAttribute('href'),location.href)}catch(x){continue}"
    "if((u.protocol=='https:'||u.protocol=='http:')&&u.hostname.replace(/^www\\./,'')==host&&"
    "u.pathname!=location.pathname&&!/log.?(in|out)|sign|account|cart|javascript/i.test(u.href)&&"
    "!a.target&&a.getBoundingClientRect().width>0)a.setAttribute('data-smoke-link',links++)}"
    "var s=document.querySelector('input[type=search],input[name=q],input[name=search],input[type=text],textarea');"
    "if(s)s.setAttribute('data-smoke-search','');"
    "return JSON.stringify({hover:hover,links:links,search:!!s})})()")


def smoke_steps(width, height):
    steps = ['eval:' + MARK_SCRIPT]
    steps += ['scrollby:%d' % (height * 3 // 4)] * 6
    steps += ['scroll:bottom']
    steps += ['scrollby:-%d' % height] * 3
    steps += ['scroll:top']
    steps += ['hover:[data-smoke-hover="%d"]' % index for index in range(6)]
    for row in range(3):
        for column in range(3):
            steps.append('hoverat:%d,%d' % (width * (column * 2 + 1) // 6, height * (row * 2 + 1) // 6))
    steps.append('drag:%d,%d,%d,%d' % (width // 10, height // 5, width * 3 // 4, height // 2))
    steps += ['click:[data-smoke-search]', 'type:hello world', 'key:Backspace']
    for link in range(3):
        steps += ['click:[data-smoke-link="%d"]' % link, 'scrollby:%d' % (height // 2),
                  'hoverat:%d,%d' % (width // 2, height // 3), 'back', 'eval:' + MARK_SCRIPT]
    steps.append('eval:document.readyState + " " + location.href')
    return steps


def parse_size(text):
    width, height = text.lower().split('x')
    return int(width), int(height)


def read_sites(path):
    sites = []
    with open(path) as source:
        for line in source:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            name, url = line.split()[:2]
            sites.append((name, url))
    return sites


def summarize_engine_output(text, returncode, elapsed, timed_out):
    """What one webbrowse run said: load time, console errors, failed
    requests, and whether it crashed, hung or timed out."""
    result = {'exit': returncode, 'seconds': round(elapsed, 1)}
    match = re.search(r'load event: (-?\d+) ms', text)
    result['load_ms'] = int(match.group(1)) if match else None
    match = re.search(r'requests: (\d+) \((\d+) unfinished\), (\d+) bytes', text)
    if match:
        result['requests'], result['unfinished'], result['bytes'] = (int(group) for group in match.groups())
    console = [line.strip() for line in text.splitlines() if re.match(r'\s+\d+ (error|warn|log|info|debug): ', line)]
    errors = [line for line in console if ' error: ' in line]
    result['console_errors'] = len(errors)
    result['uncaught'] = [line.split(' error: ', 1)[1][:200] for line in errors if 'Uncaught' in line][:8]
    failed = []
    for line in text.splitlines():
        request = NETWORK_LINE.match(line)
        if request is None:
            continue
        status, outcome = request.group(1), request.group(2)
        if status[0] in '45' or outcome.startswith('failed') or outcome.startswith('incomplete'):
            failed.append(line.strip()[:200])
    result['network_failures'] = failed[:12]
    result['network_failure_count'] = len(failed)
    engine = sorted(set(match.group(0) for match in ENGINE_FAILURES.finditer(text)))
    result['engine_failures'] = engine
    result['crashed'] = (returncode is not None and (returncode < 0 or returncode not in (0, 1, 2, 3))) or \
        bool(engine and returncode != 0)
    result['hung'] = timed_out or returncode == 3
    result['timed_out'] = returncode == 2
    if result['crashed'] or result['hung']:
        result['tail'] = text[-3000:]
    return result


def run_engine(arguments, timeout, log_path):
    began = time.time()
    timed_out = False
    try:
        completed = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
                                   cwd=REPOSITORY)
        output = completed.stdout.decode('utf-8', 'replace')
        returncode = completed.returncode
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or b'').decode('utf-8', 'replace')
        returncode = None
        timed_out = True
    with open(log_path, 'w') as log:
        log.write(' '.join(arguments) + '\n\n' + output)
    return summarize_engine_output(output, returncode, time.time() - began, timed_out)


def render_engine(url, width, height, png):
    arguments = [WEBBROWSE, '-f', FONTS, '-w', str(width), '-h', str(height), '-o', png, '-c', '-n',
                 '-t', str(RENDER_TIMEOUT), url]
    return run_engine(arguments, RENDER_TIMEOUT + WATCHDOG_GRACE, png[:-4] + '.log')


def smoke_engine(url, width, height, log):
    arguments = [WEBBROWSE, '-f', FONTS, '-w', str(width), '-h', str(height), '-c', '-n', '-q', '300',
                 '--patience', '3000', '-t', str(SMOKE_TIMEOUT)]
    for step in smoke_steps(width, height):
        arguments += ['--do', step]
    arguments.append(url)
    result = run_engine(arguments, SMOKE_TIMEOUT + WATCHDOG_GRACE, log)
    with open(log) as source:
        text = source.read()
    result['steps_run'] = len(re.findall(r'^\s*\d+ step ', text, re.M))
    result['steps'] = len(smoke_steps(width, height))
    marks = re.search(r"eval: '(\{\"hover\".*?\})'", text)
    result['marked'] = json.loads(marks.group(1)) if marks else None
    result['failed'] = result['crashed'] or result['hung']
    return result


# One reference Firefox per pool thread (each with a profile and a
# Marionette port of its own), stopped at the end.
REFERENCE_BROWSERS = []
REFERENCE_LOCK = threading.Lock()
REFERENCE_LOCAL = threading.local()


def reference_browser(out):
    browser = getattr(REFERENCE_LOCAL, 'browser', None)
    if browser is None:
        with REFERENCE_LOCK:
            worker = len(REFERENCE_BROWSERS)
            browser = ReferenceBrowser(os.path.join(out, 'firefox-profiles', 'worker-%d' % worker), 2900 + worker)
            REFERENCE_BROWSERS.append(browser)
        REFERENCE_LOCAL.browser = browser
    return browser


def render_reference(url, width, height, png, out):
    began = time.time()
    made = reference_browser(out).screenshot(url, width, height, png)
    return {'seconds': round(time.time() - began, 1), 'ok': made}


def block_statistics(image, columns, rows):
    """Per block: the mean and the standard deviation of the gray."""
    gray = ImageOps.grayscale(image)
    means = gray.resize((columns, rows), Image.BOX)
    squares = gray.point(lambda value: value * value // 255).resize((columns, rows), Image.BOX)
    mean_values = list(means.tobytes())
    square_values = list(squares.tobytes())
    deviations = []
    for mean, square in zip(mean_values, square_values):
        variance = max(0.0, square * 255.0 - mean * mean)
        deviations.append(variance ** 0.5)
    return mean_values, deviations


def difference_score(ours_path, reference_path, heat_path):
    """0 (alike) to 100; overall and for a 3 x 3 grid of regions."""
    ours = Image.open(ours_path).convert('RGB')
    reference = Image.open(reference_path).convert('RGB')
    width = min(ours.width, reference.width)
    height = min(ours.height, reference.height)
    ours = ours.crop((0, 0, width, height))
    reference = reference.crop((0, 0, width, height))
    columns, rows = max(1, width // BLOCK), max(1, height // BLOCK)
    ours_means, ours_deviations = block_statistics(ours, columns, rows)
    reference_means, reference_deviations = block_statistics(reference, columns, rows)
    blocks = []
    for index in range(columns * rows):
        mean_difference = abs(ours_means[index] - reference_means[index]) / 255.0
        contrast_difference = abs(ours_deviations[index] - reference_deviations[index]) / 128.0
        blocks.append(min(1.0, 0.5 * mean_difference + 0.5 * min(1.0, contrast_difference)))
    overall = 100.0 * sum(blocks) / len(blocks)
    regions = {}
    names = (('top', 'middle', 'bottom'), ('left', 'center', 'right'))
    for region_row in range(3):
        for region_column in range(3):
            values = [blocks[row * columns + column]
                      for row in range(region_row * rows // 3, max(region_row * rows // 3 + 1, (region_row + 1) * rows // 3))
                      for column in range(region_column * columns // 3,
                                          max(region_column * columns // 3 + 1, (region_column + 1) * columns // 3))
                      if row < rows and column < columns]
            name = names[0][region_row] + '-' + names[1][region_column]
            regions[name] = round(100.0 * sum(values) / max(1, len(values)), 1)
    heat = Image.new('L', (columns, rows))
    heat.frombytes(bytes(int(value * 255) for value in blocks))
    heat = heat.resize((width, height), Image.NEAREST)
    blend = Image.blend(ImageOps.grayscale(ours).convert('RGB'),
                        ImageOps.colorize(heat, black='black', white='red'), 0.6)
    blend.save(heat_path)
    return round(overall, 1), regions


def process_site(site, options):
    name, url = site
    site_out = os.path.join(options.out, name)
    os.makedirs(site_out, exist_ok=True)
    record = {'name': name, 'url': url, 'sizes': {}}
    for width, height in options.sizes:
        size = '%dx%d' % (width, height)
        ours = os.path.join(site_out, 'ours-%s.png' % size)
        reference = os.path.join(site_out, 'reference-%s.png' % size)
        heat = os.path.join(site_out, 'difference-%s.png' % size)
        entry = {'ours': ours, 'reference': reference, 'heat': heat}
        if not options.no_render:
            if os.path.exists(ours):
                os.remove(ours)
            entry['engine'] = render_engine(url, width, height, ours)
            if options.refresh_reference or not os.path.exists(reference):
                entry['reference_run'] = render_reference(url, width, height, reference, options.out)
            if os.path.exists(ours) and os.path.exists(reference):
                entry['score'], entry['regions'] = difference_score(ours, reference, heat)
            else:
                entry['score'] = 100.0
        record['sizes'][size] = entry
    if not options.no_smoke:
        width, height = options.sizes[0]
        record['smoke'] = smoke_engine(url, width, height, os.path.join(site_out, 'smoke.log'))
    return record


def worst_score(record):
    scores = [entry.get('score', 0) for entry in record['sizes'].values()]
    return max(scores) if scores else 0


def problems_of(record):
    problems = []
    for size, entry in record['sizes'].items():
        engine = entry.get('engine') or {}
        if engine.get('crashed'):
            problems.append('render %s CRASHED' % size)
        if engine.get('hung'):
            problems.append('render %s HUNG' % size)
        if engine.get('timed_out'):
            problems.append('render %s timed out' % size)
    smoke = record.get('smoke')
    if smoke:
        if smoke.get('crashed'):
            problems.append('smoke CRASHED')
        if smoke.get('hung'):
            problems.append('smoke HUNG')
        if smoke.get('engine_failures'):
            problems.append('engine: ' + ', '.join(smoke['engine_failures']))
    return problems


def write_reports(records, options, baseline):
    records = sorted(records, key=worst_score, reverse=True)
    sizes = ['%dx%d' % size for size in options.sizes]
    lines = ['%-20s %s %8s %6s %6s %5s  %s' % ('page', ' '.join('%9s' % size for size in sizes), 'load ms', 'errors',
                                               'netbad', 'smoke', 'problems')]
    for record in records:
        scores = []
        for size in sizes:
            entry = record['sizes'].get(size, {})
            score = entry.get('score')
            text = '%5.1f' % score if score is not None else '    -'
            old = baseline.get(record['name'], {}).get('sizes', {}).get(size, {}).get('score')
            text += ('<%4.1f' % old) if old is not None else '     '
            scores.append(text[:9].rjust(9))
        first = record['sizes'].get(sizes[0], {}).get('engine') or {}
        smoke = record.get('smoke')
        smoke_text = '-' if smoke is None else ('FAIL' if smoke.get('failed') else 'ok')
        lines.append('%-20s %s %8s %6s %6s %5s  %s' % (
            record['name'], ' '.join(scores), first.get('load_ms', '-'), first.get('console_errors', '-'),
            first.get('network_failure_count', '-'), smoke_text, '; '.join(problems_of(record))))
    lines.append('')
    lines.append('score: 0 alike .. 100 nothing alike (16 px blocks: gray mean and contrast); "a<b": now a, before b')
    with open(os.path.join(options.out, 'report.txt'), 'w') as report:
        report.write('\n'.join(lines) + '\n')
    print('\n'.join(lines))

    parts = ['<!doctype html><meta charset="utf-8"><title>Site comparison</title>',
             '<style>body{font:14px sans-serif;margin:16px}img{width:100%;border:1px solid #888}'
             '.row{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}h2{margin-top:32px}'
             'td,th{padding:2px 8px;text-align:left}pre{white-space:pre-wrap;font-size:12px}</style>',
             '<h1>Engine vs reference</h1><pre>%s</pre>' % html.escape('\n'.join(lines))]
    for record in records:
        parts.append('<h2>%s <small>%s</small></h2>' % (html.escape(record['name']), html.escape(record['url'])))
        for size in sizes:
            entry = record['sizes'].get(size)
            if not entry:
                continue
            parts.append('<p>%s: score %s, regions %s</p>' % (size, entry.get('score'),
                                                               html.escape(json.dumps(entry.get('regions', {})))))
            parts.append('<div class="row">' + ''.join(
                '<figure><a href="%s"><img src="%s"></a><figcaption>%s</figcaption></figure>' % (
                    os.path.relpath(entry[key], options.out), os.path.relpath(entry[key], options.out), label)
                for key, label in (('ours', 'webbrowse'), ('reference', 'reference'), ('heat', 'difference'))) +
                '</div>')
            engine = entry.get('engine') or {}
            if engine.get('uncaught') or engine.get('network_failures'):
                parts.append('<pre>%s</pre>' % html.escape('\n'.join(engine.get('uncaught', []) +
                                                                    engine.get('network_failures', []))))
        smoke = record.get('smoke')
        if smoke:
            parts.append('<pre>smoke: %s</pre>' % html.escape(json.dumps(
                {key: smoke.get(key) for key in ('failed', 'crashed', 'hung', 'timed_out', 'steps_run', 'steps',
                                                 'marked', 'engine_failures', 'uncaught', 'seconds')}, indent=1)))
    with open(os.path.join(options.out, 'report.html'), 'w') as report:
        report.write('\n'.join(parts))


def main():
    global WEBBROWSE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--list', default=DEFAULT_LIST)
    parser.add_argument('--out', default=DEFAULT_OUT)
    parser.add_argument('--only', default='', help='comma-separated page names')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--sizes', default='1280x800,400x800')
    parser.add_argument('--no-smoke', action='store_true')
    parser.add_argument('--no-render', action='store_true')
    parser.add_argument('--refresh-reference', action='store_true')
    parser.add_argument('--baseline', default='')
    parser.add_argument('--webbrowse', default=WEBBROWSE, help='the webbrowse binary (a copy keeps runs apart from builds)')
    options = parser.parse_args()
    options.out = os.path.abspath(options.out)
    if options.out.startswith(REPOSITORY + os.sep):
        sys.exit('compare-sites: put the output outside the repository (--out)')
    options.sizes = [parse_size(text) for text in options.sizes.split(',')]
    WEBBROWSE = os.path.abspath(options.webbrowse)
    if not os.path.exists(WEBBROWSE):
        sys.exit('compare-sites: build webbrowse first (make webbrowse)')
    if shutil.which('firefox') is None and not options.no_render:
        sys.exit('compare-sites: firefox is needed for the reference pictures')
    os.makedirs(options.out, exist_ok=True)
    sites = read_sites(options.list)
    if options.only:
        wanted = set(options.only.split(','))
        sites = [site for site in sites if site[0] in wanted]
    baseline = {}
    if options.baseline:
        with open(options.baseline) as source:
            baseline = {record['name']: record for record in json.load(source)}
    records = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=options.jobs) as pool:
        futures = {pool.submit(process_site, site, options): site for site in sites}
        for future in concurrent.futures.as_completed(futures):
            record = future.result()
            print('%-20s %s %s' % (record['name'], ' '.join(
                str(entry.get('score')) for entry in record['sizes'].values()), '; '.join(problems_of(record))),
                flush=True)
            records.append(record)
    for browser in REFERENCE_BROWSERS:
        browser.stop()
    results_path = os.path.join(options.out, 'results.json')
    if options.only and os.path.exists(results_path):
        with open(results_path) as source:
            kept = [record for record in json.load(source) if record['name'] not in {r['name'] for r in records}]
        records = kept + records
    with open(results_path, 'w') as results:
        json.dump(records, results, indent=1)
    write_reports(records, options, baseline)
    failures = [record['name'] for record in records if any('CRASHED' in problem or 'HUNG' in problem
                                                           for problem in problems_of(record))]
    if failures:
        print('compare-sites: crashed or hung: ' + ', '.join(failures))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
