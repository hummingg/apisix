#!/bin/bash
hc=0
for i in $(seq 100); do
  resp=$(curl -sL "http://127.0.0.1:9080/headers")
  if echo "$resp" | grep -q "httpbin"; then
    hc=$((hc+1))
  fi
done
echo "httpbin.org: $hc, mock.api7.ai: $((100 - hc))"
