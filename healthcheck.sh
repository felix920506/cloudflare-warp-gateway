#!/bin/sh
# Healthy = traffic is currently going through WARP.
# (When the kill switch is off and the gateway has failed over to the direct
# path, the container reports "unhealthy" so the outage is visible.)
[ "$(cat /run/warp-gateway/state 2>/dev/null)" = "warp" ]
