#!/system/bin/sh
# Root daemon for Samsung Galaxy S3 Neo (LineageOS / s3ve3g)
# Caps battery charge between 65% and 75% for 24/7 desk stand operation.

CAP_PATH="/sys/class/power_supply/battery/capacity"
CHG_PATH="/sys/class/power_supply/battery/charging_enabled"

while true; do
  if [ -f "$CAP_PATH" ] && [ -f "$CHG_PATH" ]; then
    CAP=$(cat "$CAP_PATH")
    if [ "$CAP" -ge 75 ]; then
      echo 0 > "$CHG_PATH"
    elif [ "$CAP" -le 65 ]; then
      echo 1 > "$CHG_PATH"
    fi
  fi
  sleep 60
done
