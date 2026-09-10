#!/usr/bin/env python3
"""Sube capturas a App Store Connect.

    ASC_KEY_ID=… ASC_ISSUER_ID=… upload_shots.py APP_IPHONE_67 "<locId>=slide-de-*.png"

Crea el set si no existe, borra lo que hubiera, reserva cada asset, manda los
bytes con las uploadOperations que devuelve Apple y confirma con el checksum MD5.
Tamaños que salen exactos del simulador y Apple acepta tal cual:
iPhone 17 Pro Max → 1320×2868 (APP_IPHONE_67) · iPad Pro 13" → 2064×2752
(APP_IPAD_PRO_3GEN_129)."""
import hashlib
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci_scripts"))
import asc  # noqa: E402


def find_or_create_set(loc_id, display_type):
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    for s in sets["data"]:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"], False
    r = asc.request("/v1/appScreenshotSets", "POST", {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": loc_id}}},
        }
    })
    return r["data"]["id"], True


def clear_set(set_id):
    shots = asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    for s in shots["data"]:
        asc.request(f"/v1/appScreenshots/{s['id']}", "DELETE")
    return len(shots["data"])


def upload(set_id, path: Path):
    data = path.read_bytes()
    reserved = asc.request("/v1/appScreenshots", "POST", {
        "data": {
            "type": "appScreenshots",
            "attributes": {"fileSize": len(data), "fileName": path.name},
            "relationships": {"appScreenshotSet": {
                "data": {"type": "appScreenshotSets", "id": set_id}}},
        }
    })
    shot_id = reserved["data"]["id"]
    for op in reserved["data"]["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op["requestHeaders"]:
            req.add_header(header["name"], header["value"])
        with urllib.request.urlopen(req, timeout=180) as resp:
            assert resp.status in (200, 201, 204), resp.status
    asc.request(f"/v1/appScreenshots/{shot_id}", "PATCH", {
        "data": {"type": "appScreenshots", "id": shot_id,
                 "attributes": {"uploaded": True,
                                "sourceFileChecksum": hashlib.md5(data).hexdigest()}}
    })
    return shot_id


def wait_for_delivery(shot_ids, tries=20):
    pending = list(shot_ids)
    while pending and tries:
        time.sleep(6)
        tries -= 1
        still = []
        for sid in pending:
            state = asc.get(f"/v1/appScreenshots/{sid}")["data"]["attributes"].get(
                "assetDeliveryState") or {}
            if state.get("state") == "COMPLETE":
                continue
            if state.get("errors"):
                print(f"   !! {sid}: {state['errors']}")
                continue
            still.append(sid)
        pending = still
    return pending


if __name__ == "__main__":
    SLIDES = Path(__file__).parent / "slides"
    display_type = sys.argv[1]
    # Resto de argumentos: "<idDeLocalización>=<patrón>" — así el script sirve para
    # cualquier versión y locale, no solo los de 1.0.8.
    targets = {}
    for arg in sys.argv[2:]:
        loc_id, pattern = arg.split("=", 1)
        targets[loc_id[:8]] = (loc_id, pattern)
    for locale, (loc_id, pattern) in targets.items():
        files = sorted(SLIDES.glob(pattern))
        assert files, f"sin archivos para {pattern}"
        set_id, created = find_or_create_set(loc_id, display_type)
        removed = clear_set(set_id)
        print(f"{locale}: set {display_type} {'creado' if created else 'existente'} "
              f"({removed} capturas viejas borradas) → subiendo {len(files)}")
        ids = []
        for f in files:
            ids.append(upload(set_id, f))
            print(f"   ✓ {f.name}")
        failed = wait_for_delivery(ids)
        print(f"   entrega: {len(ids) - len(failed)}/{len(ids)} COMPLETE")
