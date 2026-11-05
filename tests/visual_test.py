#!/usr/bin/env python3
from pathlib import Path
import subprocess
import time

def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=8).stdout.strip()

run('omarchy-shell', 'shell', 'summon', 'nov.dock')
time.sleep(.45)
run('grim', '/tmp/nov-floating-window-menu.png')
run('omarchy-shell', 'shell', 'hide', 'nov.dock')
run('omarchy-shell', 'omarchy.dock', 'downloads')
time.sleep(.6)
run('grim', '/tmp/nov-floating-downloads-fan.png')
run('omarchy-shell', 'omarchy.dock', 'downloads')
print('Captured window menu and Downloads fan; both panels closed again.')
