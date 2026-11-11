#!/usr/bin/env python3
"""Envía la versión siguiente en cuanto la anterior queda publicada.

    ASC_KEY_ID=… ASC_ISSUER_ID=… release_after.py 1.0.16 1.0.17 78 [horas]

App Store Connect no deja crear una versión mientras otra está en revisión
(409 «You cannot create a new version of the App in the current state»). Este
script espera a que <anterior> llegue a READY_FOR_SALE (o PENDING_DEVELOPER_RELEASE)
y entonces: crea <siguiente> con publicación automática, le carga las novedades
de «## What's New (<siguiente>)» de AppStoreMetadata.md (es-MX, en-US, de-DE,
pt-BR, en ese orden de bloques), copia el texto promocional (POST no lo copia),
adjunta el build <número> y la envía a revisión.

Sale con 0 si la envió, 4 si la anterior fue rechazada o retirada (no envía
nada), 3 si se agota la espera y 1 ante cualquier error de la API.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci_scripts"))
import asc  # noqa: E402

APP = "6772419323"
API = "https://api.appstoreconnect.apple.com"
METADATA = Path(__file__).resolve().parents[2] / "AppStoreMetadata.md"
LOCALES = ["es-MX", "en-US", "de-DE", "pt-BR"]  # orden de los bloques en el .md
LIVE = {"READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE"}
DEAD = {"REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "INVALID_BINARY", "REMOVED_FROM_SALE"}


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def call(path, method="GET", body=None, tries=4):
    """GET con reintentos (la red se cae a ratos); POST/PATCH una sola vez."""
    for attempt in range(tries if method == "GET" else 1):
        req = urllib.request.Request(
            API + path, method=method, data=json.dumps(body).encode() if body else None,
            headers={"Authorization": f"Bearer {asc.make_jwt()}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")
        except Exception as e:  # noqa: BLE001
            log(f"(red: {type(e).__name__}, reintento {attempt + 1})")
            time.sleep(15)
    return 0, {}


def must(status_body, what):
    status, body = status_body
    if status >= 300 or status == 0:
        errs = "; ".join(f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in body.get("errors", []))
        log(f"ERROR {what}: {status} {errs}")
        sys.exit(1)
    return body


def versions():
    _, b = call(f"/v1/apps/{APP}/appStoreVersions?limit=5")
    return {v["attributes"]["versionString"]: v for v in b.get("data", [])}


def whats_new(version):
    md = METADATA.read_text()
    start = md.index(f"## What's New ({version})")
    blocks = re.findall(r"```\n(.*?)\n```", md[start:], re.S)[: len(LOCALES)]
    assert len(blocks) == len(LOCALES), "faltan bloques de novedades en AppStoreMetadata.md"
    return dict(zip(LOCALES, blocks))


def wait_for(prev, deadline):
    while time.time() < deadline:
        v = versions().get(prev)
        state = v["attributes"]["appStoreState"] if v else "?"
        if state in LIVE:
            log(f"{prev} publicada ({state})")
            return True
        if state in DEAD:
            log(f"{prev} quedó en {state}: no envío nada")
            sys.exit(4)
        log(f"{prev} en {state}, espero")
        time.sleep(600)
    return False


def build_id(number, version, deadline):
    while time.time() < deadline:
        _, b = call(f"/v1/builds?filter[app]={APP}&filter[version]={number}&include=preReleaseVersion")
        for build in b.get("data", []):
            pre = {p["id"]: p["attributes"]["version"] for p in b.get("included", [])}
            rel = (build.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
            if pre.get(rel) != version:
                log(f"ERROR: el build {number} es de {pre.get(rel)}, no de {version}")
                sys.exit(1)
            if build["attributes"]["processingState"] == "VALID":
                return build["id"]
        log(f"build {number} todavía no está listo, espero")
        time.sleep(300)
    log(f"ERROR: el build {number} no apareció")
    sys.exit(3)


def main(prev, nxt, number, hours):
    deadline = time.time() + hours * 3600
    notes = whats_new(nxt)
    bid = build_id(number, nxt, deadline)
    if not wait_for(prev, deadline):
        log("se agotó la espera")
        sys.exit(3)

    existing = versions().get(nxt)
    if existing:
        ver = existing["id"]
        log(f"{nxt} ya existía ({existing['attributes']['appStoreState']})")
    else:
        ver = must(call("/v1/appStoreVersions", "POST", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": nxt, "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}}), f"crear {nxt}")["data"]["id"]
        log(f"{nxt} creada")
        time.sleep(10)

    prev_promo = {}
    pv = versions().get(prev)
    if pv:
        _, b = call(f"/v1/appStoreVersions/{pv['id']}/appStoreVersionLocalizations")
        prev_promo = {l["attributes"]["locale"]: l["attributes"].get("promotionalText") for l in b.get("data", [])}
    _, b = call(f"/v1/appStoreVersions/{ver}/appStoreVersionLocalizations")
    for loc in b.get("data", []):
        locale = loc["attributes"]["locale"]
        attrs = {}
        if locale in notes:
            attrs["whatsNew"] = notes[locale]
        if prev_promo.get(locale) and not loc["attributes"].get("promotionalText"):
            attrs["promotionalText"] = prev_promo[locale]
        if attrs:
            must(call(f"/v1/appStoreVersionLocalizations/{loc['id']}", "PATCH", {"data": {
                "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}}), f"ficha {locale}")
            log(f"ficha {locale}: {', '.join(attrs)}")

    # Datos de contacto para la revisión: si la versión nueva no los trae, se copian.
    status, rd = call(f"/v1/appStoreVersions/{ver}/appStoreReviewDetail")
    if status >= 300 or not rd.get("data"):
        _, old = call(f"/v1/appStoreVersions/{pv['id']}/appStoreReviewDetail") if pv else (0, {})
        a = (old.get("data") or {}).get("attributes", {})
        keep = {k: a.get(k) for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail") if a.get(k)}
        keep["demoAccountRequired"] = False
        must(call("/v1/appStoreReviewDetails", "POST", {"data": {
            "type": "appStoreReviewDetails", "attributes": keep,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver}}}}}), "datos de revisión")
        log("datos de revisión copiados")

    must(call(f"/v1/appStoreVersions/{ver}/relationships/build", "PATCH", {"data": {"type": "builds", "id": bid}}), "adjuntar build")
    log(f"build {number} adjuntado")

    _, b = call(f"/v1/apps/{APP}/reviewSubmissions?filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES")
    if b.get("data"):
        sub = b["data"][0]["id"]
    else:
        sub = must(call("/v1/reviewSubmissions", "POST", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}}), "crear envío")["data"]["id"]
    _, items = call(f"/v1/reviewSubmissions/{sub}/items")
    if not items.get("data"):
        must(call("/v1/reviewSubmissionItems", "POST", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver}}}}}), "añadir versión al envío")
    body = must(call(f"/v1/reviewSubmissions/{sub}", "PATCH", {"data": {
        "type": "reviewSubmissions", "id": sub, "attributes": {"submitted": True}}}), "enviar")
    log(f"envío: {body['data']['attributes'].get('state')}")
    time.sleep(5)
    log(f"{nxt} → {versions()[nxt]['attributes']['appStoreState']}")


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 72)
