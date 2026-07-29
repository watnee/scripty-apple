#!/bin/bash
#
# Double-click this in Finder to put Scripty on the iPhones and iPads plugged
# into this Mac — no terminal, no commands to type. It checks Xcode the way the
# other launchers do, then waits for a device, builds a signed copy, and installs
# and opens it on every device it finds, so a phone and a tablet on the same desk
# are one double-click rather than two. A free Apple ID is enough to sign; if
# Developer Mode is off or a device hasn't trusted the certificate yet, it says
# exactly what to tap and waits while you do it, rather than failing in the
# build log.
#
# Unlike Install Scripty.command, which opens the offline demo in a simulator
# when nothing is plugged in, this one insists on a real device and waits for
# one to appear. Plug the device in over USB and unlock it before, or just after,
# you double-click.
#
# It lives next to the project so it works whether you cloned the repository or
# downloaded it as a ZIP from GitHub. If macOS says it is from an unidentified
# developer the first time, right-click it and choose Open.
#
cd "$(dirname "$0")"
if [ ! -x scripts/finder-run.sh ]; then
    echo "This file has to stay next to Scripty's scripts folder to work." >&2
    echo "It looks like it was moved out of the project." >&2
    read -r -p "Press Return to close this window." _ || true
    exit 1
fi

# Say the three physical steps up front, before the Xcode checks and the build
# scroll past, so someone who has never done this knows what to do and that the
# window handles the rest. Anything else that comes up — Developer Mode, trusting
# the app — is spelled out by the lines below as it happens.
cat <<'EOF'
Putting Scripty on your iPhone and iPad. All you do is:

  1. Plug them into this Mac with a cable — one, or both, or however many.
  2. Unlock each one, and tap "Trust This Computer" if it asks.
  3. Leave this window running — it builds Scripty, then installs and opens
     it on every device it finds.

You can start now; it waits for the devices to show up.

EOF
exec scripts/finder-run.sh "The install" ./scripts/get.sh -- --all
