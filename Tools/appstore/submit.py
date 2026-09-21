#!/usr/bin/env python3
"""Adjunta un build a una versión de la App Store y la envía a revisión.

    ASC_KEY_ID=… ASC_ISSUER_ID=… submit.py 1.0.9 60

El build lo pone Xcode Cloud y su número coincide con el de la corrida, no con
`git rev-list --count`. La versión tiene que existir ya en App Store Connect
(POST /v1/appStoreVersions) con su ficha cargada.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci_scripts"))
import asc  # noqa: E402

APP = "6772419323"


# Estados desde los que una versión se puede editar y (re)enviar.
# DEVELOPER_REJECTED es donde queda al retirarla de la cola uno mismo
# (PATCH /v1/reviewSubmissions/{id} {canceled: true}) para cambiarle el build.
SUBMITTABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"}


def version_id(version_string: str) -> str:
    for v in asc.get(f"/v1/apps/{APP}/appStoreVersions?limit=10")["data"]:
        if v["attributes"]["versionString"] == version_string:
            state = v["attributes"]["appStoreState"]
            print(f"versión {version_string} · {state}")
            if state not in SUBMITTABLE:
                sys.exit(f"la versión está en {state}; se puede enviar desde {sorted(SUBMITTABLE)}")
            return v["id"]
    sys.exit(f"no encontré la versión {version_string}")


def build_id(number: str, version_string: str) -> str:
    for b in asc.get(f"/v1/builds?filter[app]={APP}&limit=10&sort=-uploadedDate")["data"]:
        if b["attributes"]["version"] != number:
            continue
        pre = asc.get(f"/v1/builds/{b['id']}/preReleaseVersion")
        got = (pre.get("data") or {}).get("attributes", {}).get("version")
        state = b["attributes"].get("processingState")
        print(f"build {number} · v{got} · {state}")
        if got != version_string:
            sys.exit(f"el build {number} es de {got}, no de {version_string}")
        if state != "VALID":
            sys.exit(f"el build {number} está en {state}, hay que esperar a VALID")
        return b["id"]
    sys.exit(f"no encontré el build {number}")


def attach(version: str, bid: str):
    asc.request(f"/v1/appStoreVersions/{version}/relationships/build", "PATCH",
                {"data": {"type": "builds", "id": bid}})
    got = asc.get(f"/v1/appStoreVersions/{version}/build")
    print("build adjuntado:", (got.get("data") or {}).get("id") == bid)


def open_submission() -> str:
    """Reutiliza el envío abierto si ya hay uno; crearlo dos veces da 409."""
    existing = asc.get(f"/v1/apps/{APP}/reviewSubmissions"
                       "?filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES,WAITING_FOR_REVIEW")
    for s in existing.get("data", []):
        print("envío existente:", s["id"], s["attributes"].get("state"))
        return s["id"]
    r = asc.request("/v1/reviewSubmissions", "POST",
                    {"data": {"type": "reviewSubmissions",
                              "attributes": {"platform": "IOS"},
                              "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    print("envío creado:", r["data"]["id"])
    return r["data"]["id"]


def add_item(submission: str, version: str, version_string: str):
    if asc.get(f"/v1/reviewSubmissions/{submission}/items").get("data"):
        print("el envío ya tiene ítems")
        return
    asc.request("/v1/reviewSubmissionItems", "POST",
                {"data": {"type": "reviewSubmissionItems",
                          "relationships": {
                              "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version}}}}})
    print(f"ítem agregado: la versión {version_string}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    version_string, number = sys.argv[1], sys.argv[2]
    version = version_id(version_string)
    attach(version, build_id(number, version_string))
    submission = open_submission()
    add_item(submission, version, version_string)
    r = asc.request(f"/v1/reviewSubmissions/{submission}", "PATCH",
                    {"data": {"type": "reviewSubmissions", "id": submission,
                              "attributes": {"submitted": True}}})
    print("envío:", r["data"]["attributes"].get("state"))
    state = asc.get(f"/v1/appStoreVersions/{version}")["data"]["attributes"]["appStoreState"]
    print(f"{version_string} → {state}")
