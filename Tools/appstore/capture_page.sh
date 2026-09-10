#!/bin/bash
D=${DEVICE:?exporta DEVICE con el UDID del simulador}
BUNDLE=MathyuSolutions.Calarm
xcrun simctl terminate $D $BUNDLE >/dev/null 2>&1
xcrun simctl launch $D $BUNDLE -AppleLanguages "($1)" -seedDemoData -demoScreen onboarding -demoPage "$2" >/dev/null 2>&1
sleep 4
xcrun simctl io $D screenshot "$3" >/dev/null 2>&1
echo "→ $3"
