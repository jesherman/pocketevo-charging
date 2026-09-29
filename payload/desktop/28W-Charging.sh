#!/bin/bash
# Convenience wrapper for the Pocket EVO 28 W charging pack.
# With no arguments it opens the interactive menu.
if [ "$#" -eq 0 ]; then
	exec /var/armada/charging/bin/charging-control.sh menu
fi
exec /var/armada/charging/bin/charging-control.sh "$@"
