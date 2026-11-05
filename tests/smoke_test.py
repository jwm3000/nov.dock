#!/usr/bin/env python3
"""Live tests operate on disposable terminals, then restore the original focus."""
import json
from pathlib import Path
import subprocess
import time

HELPER = str(Path.home() / '.config/omarchy/plugins/nov.dock/desktop.py')

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=8).stdout.strip()

def clients():
    return json.loads(run('hyprctl', 'clients', '-j'))

def get(address):
    return next(w for w in clients() if w['address'] == address)

def wait_for(predicate):
    for _ in range(40):
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise AssertionError('Timed out waiting for the desktop')

def dispatch(code):
    result = run('hyprctl', 'dispatch', code)
    assert result == 'ok', result

original = json.loads(run('hyprctl', 'activewindow', '-j')).get('address')
existing = {w['address'] for w in clients()}
created = set()
terminal = None
try:
    plugins = json.loads(run('hyprctl', 'plugin', 'list', '-j'))
    assert any(p['name'] == 'nov-floating-snap' for p in plugins), plugins
    terminal = subprocess.Popen(['foot', '--app-id=nov-floating-dock-test', '--title=Floating Dock Test', 'sleep', '90'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    address = wait_for(lambda: next((w['address'] for w in clients() if w['class'] == 'nov-floating-dock-test'), None))
    created.add(address)
    workspace = get(address)['workspace']['id']
    before = get(address)
    assert before['floating']
    dispatch(f'hl.dsp.focus({{ window = "address:{address}" }})')
    run('python3', HELPER, 'border', address)
    assert run('hyprctl', 'getprop', 'address:' + address, 'border_size') == '0'
    assert 'nov-dock-borderless' in get(address)['tags']
    run('python3', HELPER, 'border', address)
    assert 'nov-dock-borderless' not in get(address)['tags']
    print('PASS per-window border off/on', flush=True)
    for direction in ('left', 'right'):
        run('hyprctl', 'eval', f'hl.plugin.nov_floating_snap.{direction}()')
        time.sleep(.4)
        window = get(address)
        assert window['floating'] and window['size'][0] < before['size'][0], window
        print('PASS snap', direction, window['at'], window['size'], flush=True)
    run('hyprctl', 'eval', 'hl.plugin.nov_floating_snap.maximize()')
    time.sleep(.4)
    assert get(address)['fullscreen'] == 2
    run('hyprctl', 'eval', 'hl.plugin.nov_floating_snap.restore()')
    time.sleep(.4)
    assert get(address)['fullscreen'] == 0
    print('PASS fullscreen and restore', flush=True)
    run('python3', HELPER, 'minimize', address)
    assert get(address)['workspace']['name'] == 'special:minimized'
    dispatch(f'hl.dsp.window.move({{ workspace = "{workspace}", window = "address:{address}" }})')
    assert get(address)['workspace']['id'] == workspace
    print('PASS minimize and restore', flush=True)
    before_new = {w['address'] for w in clients()}
    run('python3', HELPER, 'new-window', 'foot')
    extra = wait_for(lambda: next((w['address'] for w in clients() if w['class'] == 'foot' and w['address'] not in before_new), None))
    created.add(extra)
    print('PASS New Window opens an additional terminal', flush=True)
    assert run('hyprctl', 'configerrors') == ''
    print('PASS no Hyprland configuration errors', flush=True)
finally:
    for address in created:
        if address not in existing and any(w['address'] == address for w in clients()):
            dispatch(f'hl.dsp.window.close({{ window = "address:{address}" }})')
    if terminal and terminal.poll() is None:
        terminal.terminate()
    if original and any(w['address'] == original for w in clients()):
        dispatch(f'hl.dsp.focus({{ window = "address:{original}" }})')
