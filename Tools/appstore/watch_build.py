#!/usr/bin/env python3
"""Espera a que una corrida de Xcode Cloud archive y suba su build.

    ASC_KEY_ID=… ASC_ISSUER_ID=… watch_build.py 60

Sale con 0 en cuanto el build aparece en App Store Connect, con 2 si el Archive
falló (imprimiendo los errores) y con 3 si se agota la espera.

Dos cosas que hacen falta y no son obvias:
  · `asc.request` hace sys.exit(1) ante cualquier HTTP != 2xx, y urllib tira
    timeouts de SSL cada tanto — un sondeo sin `safe()` se muere a la primera.
  · `/buildRuns` pagina ASCENDENTE: con limit bajo devuelve las corridas más
    viejas, no las últimas.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci_scripts"))
import asc  # noqa: E402

APP = "6772419323"
PRODUCT = "B28FD415-34A8-4606-AFC1-F7A5611660B4"


def safe(fn, *args):
    try:
        return fn(*args)
    except SystemExit:
        return None
    except Exception as e:
        print(f"   (red: {type(e).__name__})", flush=True)
        return None


def main(target_run: int, minutes: int = 50) -> int:
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        runs = safe(asc.get, f"/v1/ciProducts/{PRODUCT}/buildRuns?limit=20")
        run = next((r for r in (runs or {}).get("data", [])
                    if r["attributes"]["number"] == target_run), None)
        if run:
            archive = next((a for a in (safe(asc.get, f"/v1/ciBuildRuns/{run['id']}/actions") or {}).get("data", [])
                            if a["attributes"]["actionType"] == "ARCHIVE"), None)
            at = (archive or {}).get("attributes", {})
            print(f"[{time.strftime('%H:%M:%S')}] corrida {target_run} · archive "
                  f"{at.get('executionProgress')} / {at.get('completionStatus')}", flush=True)

            if at.get("completionStatus") in ("FAILED", "ERRORED", "CANCELED"):
                print(f"ARCHIVE {at['completionStatus']}")
                issues = safe(asc.get, f"/v1/ciBuildActions/{archive['id']}/issues?limit=20")
                for i in (issues or {}).get("data", []):
                    if i["attributes"].get("issueType") == "ERROR":
                        print("  ERROR:", i["attributes"].get("message", "")[:400])
                return 2

            if at.get("completionStatus") == "SUCCEEDED":
                builds = safe(asc.get, f"/v1/builds?filter[app]={APP}&limit=5&sort=-uploadedDate")
                for b in (builds or {}).get("data", []):
                    if b["attributes"]["version"] == str(target_run):
                        print(f"LISTO: build {b['attributes']['version']} · "
                              f"{b['attributes'].get('processingState')} · id {b['id']}")
                        return 0
                print("   archive OK, el build aún no aparece en ASC…", flush=True)
        time.sleep(60)
    print("se agotó la espera")
    return 3


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(int(sys.argv[1])))
