#!/usr/bin/env bash
# sudo bash scripts/verify-hub.sh prepare | upgrade | finish
# The prepare/upgrade modes leave an owned container running for browser screenshots.
set -Eeuo pipefail
umask 077

mode="${1:-}"
case "$mode" in prepare|upgrade|finish) ;; *) echo 'Usage: verify-hub.sh prepare|upgrade|finish' >&2; exit 2 ;; esac
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$project_dir"
docker info --format 'Docker server {{.ServerVersion}}' >/dev/null
command -v python3 >/dev/null
mkdir -p -- evidence
state_file="$project_dir/evidence/.hub-verification-state"
refs=(lab-app:1.0 lab-app:1.1 nyrigin/lab-app:1.0 nyrigin/lab-app:1.1 nyrigin/lab-app:latest)

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

guard_local_container() {
    local name="$1" version="$2" actual
    actual="$(docker container inspect --format '{{.Id}}|{{.Config.Image}}|{{index .Config.Labels "com.codex.dockerhub-lab.version"}}|{{index .Config.Labels "com.codex.dockerhub-lab.run"}}' "$name")"
    IFS='|' read -r found_id found_image found_version found_run <<< "$actual"
    [[ "$found_image" == "lab-app:$version" && "$found_version" == "$version" && "$found_run" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || {
        echo "Refusing to change container $name: local lab image/ownership labels do not match" >&2
        exit 1
    }
}

guard_hub_container() {
    local actual
    actual="$(docker container inspect --format '{{.Id}}|{{.Config.Image}}|{{index .Config.Labels "com.codex.dockerhub-lab.version"}}|{{index .Config.Labels "com.codex.dockerhub-lab.verify.run"}}' lab-app)"
    IFS='|' read -r found_id found_image found_version found_run <<< "$actual"
    [[ "$found_run" == "$run_id" && ( "$found_version" == 1.0 || "$found_version" == 1.1 ) && "$found_image" == "nyrigin/lab-app:$found_version" ]] || {
        echo 'Refusing to change lab-app: Docker Hub image/verification ownership labels do not match' >&2
        exit 1
    }
}

check_http() {
    local version="$1"
    python3 - "$version" "$evidence_dir" <<'PY'
import datetime
import json
import pathlib
import sys
import time
import urllib.request

version, output = sys.argv[1:]
expected = 'Привет из контейнера!' if version == '1.0' else 'Привет из контейнера! Версия 1.1.'
url = 'http://127.0.0.1:8080/'
for attempt in range(60):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            body_bytes = response.read()
            body = body_bytes.decode('utf-8')
            status = response.status
            headers = dict(response.headers)
            assert status == 200, status
            assert response.headers.get_content_charset() == 'utf-8', headers
            assert response.headers['X-App-Version'] == version, headers
            assert body == expected, repr(body)
        break
    except Exception:
        if attempt == 59:
            raise
        time.sleep(0.5)
output = pathlib.Path(output)
(output / f'response-{version}.txt').write_bytes(body_bytes)
(output / f'http-{version}.json').write_text(json.dumps({
    'checked_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'url': url, 'status': status, 'headers': headers,
    'body': body, 'version': version, 'passed': True,
}, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'HTTP {status}; downloaded image version {version}; response: {body}')
PY
}

snapshot_running() {
    local version="$1"
    run docker ps --no-trunc --filter 'name=^/lab-app$' | tee "$evidence_dir/docker-ps-$version.txt"
    run docker logs lab-app 2>&1 | tee "$evidence_dir/logs-$version.txt"
    docker container inspect lab-app > "$evidence_dir/container-inspect-$version.json"
    docker image inspect "nyrigin/lab-app:$version" > "$evidence_dir/image-inspect-$version.json"
    run docker image inspect --format '{{index .RepoTags 0}} ID={{.Id}} SIZE_BYTES={{.Size}} DIGESTS={{json .RepoDigests}}' \
        "nyrigin/lab-app:$version" | tee "$evidence_dir/image-summary-$version.txt"
}

pull_run() {
    local version="$1" image="nyrigin/lab-app:$1"
    [[ ! $(docker container ls -aq --filter 'name=^/lab-app$') ]] || {
        echo 'Container name lab-app is occupied; refusing to replace it' >&2; exit 1;
    }
    run docker pull "$image" 2>&1 | tee "$evidence_dir/pull-$version.txt"
    run docker run -d --name lab-app \
        --label "com.codex.dockerhub-lab.verify.run=$run_id" \
        --label "com.codex.dockerhub-lab.version=$version" \
        -p 8080:8000 "$image"
    check_http "$version"
    snapshot_running "$version"
    printf 'READY_VERSION=%s URL=http://localhost:8080\n' "$version" | tee "$evidence_dir/ready-$version.txt"
}

if [[ "$mode" == prepare ]]; then
    [[ ! -e "$state_file" ]] || { echo 'A verification state already exists; finish or inspect it before preparing again' >&2; exit 1; }
    if container_exists lab-app; then
        echo 'Container lab-app already exists; no images or containers were removed' >&2
        exit 1
    fi
    old_ids=()
    for pair in dockerhub-lab-v10:1.0 dockerhub-lab-v11:1.1; do
        name="${pair%%:*}"
        version="${pair#*:}"
        if container_exists "$name"; then
            guard_local_container "$name" "$version"
            old_ids+=("$found_id")
        fi
    done
    target_ids=()
    for ref in "${refs[@]}"; do
        if docker image inspect "$ref" >/dev/null 2>&1; then
            target_ids+=("$(docker image inspect --format '{{.Id}}' "$ref")")
        fi
    done
    # Check every container using these exact image IDs before any deletion.
    # Existing Express/base images and unrelated containers are never targeted.
    while IFS= read -r container_id; do
        [[ -n "$container_id" ]] || continue
        image_id="$(docker container inspect --format '{{.Image}}' "$container_id")"
        uses_target=0
        for target_id in "${target_ids[@]}"; do
            [[ "$image_id" != "$target_id" ]] || uses_target=1
        done
        if [[ "$uses_target" -eq 1 ]]; then
            owned=0
            for old_id in "${old_ids[@]}"; do
                [[ "$container_id" != "$old_id" ]] || owned=1
            done
            [[ "$owned" -eq 1 ]] || { echo "Refusing deletion: another container uses a lab image: $container_id" >&2; exit 1; }
        fi
    done < <(docker container ls -aq --no-trunc)

    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    evidence_dir="$project_dir/evidence/hub-$run_id"
    mkdir -- "$evidence_dir"
    exec > >(tee "$evidence_dir/session-prepare.log") 2>&1
    printf '%s\n' "$run_id" > "$state_file"
    echo "Verification run $run_id; removing only five exact local lab image references"
    docker images --digests lab-app > "$evidence_dir/before-images-local.txt"
    docker images --digests nyrigin/lab-app > "$evidence_dir/before-images-hub.txt"
    for container_id in "${old_ids[@]}"; do
        run docker stop "$container_id"
        run docker rm "$container_id"
    done
    for ref in "${refs[@]}"; do
        if docker image inspect "$ref" >/dev/null 2>&1; then
            run docker rmi "$ref"
        fi
    done
    for ref in "${refs[@]}"; do
        if docker image inspect "$ref" >/dev/null 2>&1; then
            echo "Required local image reference still exists: $ref" >&2
            exit 1
        fi
        echo "ABSENT_LOCAL_IMAGE=$ref"
    done
    docker images --digests lab-app > "$evidence_dir/after-removal-images-local.txt"
    docker images --digests nyrigin/lab-app > "$evidence_dir/after-removal-images-hub.txt"
    echo 'Local application tags are absent. Shared layers/build cache may remain, as allowed by the assignment.'
    pull_run 1.0
    echo "Save a genuine browser screenshot, then run upgrade. Evidence: $evidence_dir"
    exit 0
fi

[[ -f "$state_file" ]] || { echo 'Verification state is missing; prepare must run first' >&2; exit 1; }
run_id="$(cat -- "$state_file")"
[[ "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || { echo 'Invalid verification state' >&2; exit 1; }
evidence_dir="$project_dir/evidence/hub-$run_id"
[[ -d "$evidence_dir" ]] || { echo 'Verification evidence directory is missing' >&2; exit 1; }
container_exists lab-app || { echo 'Owned verification container is missing' >&2; exit 1; }
guard_hub_container
exec > >(tee "$evidence_dir/session-$mode.log") 2>&1

if [[ "$mode" == upgrade ]]; then
    [[ "$found_version" == 1.0 ]] || { echo 'Upgrade requires the owned version 1.0 container' >&2; exit 1; }
    previous_id="$found_id"
    run docker logs "$previous_id" 2>&1 | tee "$evidence_dir/logs-1.0-before-upgrade.txt"
    run docker stop "$previous_id"
    run docker rm "$previous_id"
    pull_run 1.1
    echo 'Save a genuine browser screenshot of version 1.1, then run finish.'
else
    final_id="$found_id"
    final_version="$found_version"
    snapshot_running "$final_version"
    run docker stop "$final_id"
    run docker rm "$final_id"
    printf 'Owned verification container stopped and removed; images retained. UTC %s\n' \
        "$(date -u +%FT%TZ)" | tee "$evidence_dir/finished.txt"
    rm -- "$state_file"
fi
