#!/bin/bash

DEVICE_ID=9

STATUS=$(xinput list-props $DEVICE_ID | grep "Device Enabled" | awk '{print $4}')

if [ "$STATUS" -eq 1 ]; then
    xinput disable $DEVICE_ID
    notify-send "Touchscreen Disabled"
else
    xinput enable $DEVICE_ID
    notify-send "Touchscreen Enabled"
fi
