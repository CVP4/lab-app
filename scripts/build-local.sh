#!/usr/bin/env bash
# Run from Debian: sudo bash scripts/build-local.sh
# Builds and checks only local images. No registry login, tag, or push is used.
# Successful containers remain running for genuine browser screenshots.
set -Eeuo pipefail
umask 077

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$project_dir"
command -v docker >/dev/null || { echo 'Docker CLI is missing' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is missing' >&2; exit 1; }
docker info --format 'Docker server {{.ServerVersion}}' >/dev/null
[[ -f app.py && -f Dockerfile && -f .dockerignore ]] || {
    echo 'Run from the prepared lab-app project; required files are missing' >&2
    exit 1
}

for image in lab-app:1.0 lab-app:1.1; do
    if docker image inspect "$image" >/dev/null 2>&1; then
        echo "Refusing to overwrite existing image: $image" >&2
        exit 1
    fi
done
for name in dockerhub-lab-v10 dockerhub-lab-v11; do
    if docker container inspect "$name" >/dev/null 2>&1; then
        echo "Refusing to replace existing container: $name" >&2
        exit 1
    fi
done

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
evidence_dir="$project_dir/evidence/local-$run_id"
mkdir -p -- "$evidence_dir"
exec > >(tee "$evidence_dir/session.log") 2>&1
backup_dir="$(mktemp -d)"
cp -- app.py "$backup_dir/app.py"
source_hash="$(sha256sum app.py | cut -d ' ' -f 1)"
container_ids=()
completed=0

finish() {
    local result=$?
    trap - EXIT INT TERM
    if ! cp -- "$backup_dir/app.py" "$project_dir/app.py"; then
        echo "ERROR: restore app.py manually from $backup_dir/app.py" >&2
        result=1
    elif ! cmp -s -- "$backup_dir/app.py" "$project_dir/app.py"; then
        echo "ERROR: source restore mismatch; backup preserved: $backup_dir/app.py" >&2
        result=1
    else
        echo "app.py restored byte-for-byte; SHA256 $source_hash"
        rm -- "$backup_dir/app.py"
        rmdir -- "$backup_dir"
    fi
    if [[ "$completed" -ne 1 || "$result" -ne 0 ]]; then
        # Only IDs successfully created by this invocation can be removed.
        for container_id in "${container_ids[@]}"; do
            docker rm -f "$container_id" >/dev/null 2>&1 || true
        done
    fi
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "UTC run ID: $run_id"
echo "Evidence: $evidence_dir"
echo "Original app.py SHA256: $source_hash"
docker version | tee "$evidence_dir/docker-version.txt"

for version in 1.0 1.1; do
    # Start each edit from the original bytes, preserving all unrelated source.
    python3 - "$backup_dir/app.py" "$project_dir/app.py" "$version" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_bytes()
pattern = rb'(?m)^VERSION = "\d+\.\d+(?:\.\d+)?"(?=\r?$)'
if len(re.findall(pattern, source)) != 1:
    raise SystemExit('VERSION constant must occur exactly once')
updated = re.sub(pattern, ('VERSION = "' + sys.argv[3] + '"').encode('ascii'), source)
pathlib.Path(sys.argv[2]).write_bytes(updated)
PY
    cp -- app.py "$evidence_dir/app-$version.py"
    echo "+ docker build -t lab-app:$version ."
    docker build -t "lab-app:$version" . 2>&1 | tee "$evidence_dir/build-$version.txt"
    if [[ "$version" == 1.0 ]]; then
        port=8000
        name=dockerhub-lab-v10
    else
        port=8080
        name=dockerhub-lab-v11
    fi
    echo "+ docker create --name $name -p $port:8000 lab-app:$version"
    container_id="$(docker create --name "$name" \
        --label "com.codex.dockerhub-lab.run=$run_id" \
        --label "com.codex.dockerhub-lab.version=$version" \
        -p "$port:8000" "lab-app:$version")"
    container_ids+=("$container_id")
    docker start "$container_id"

    python3 - "$version" "$port" "$evidence_dir" <<'PY'
import datetime
import json
import pathlib
import sys
import time
import urllib.request

version, port, output = sys.argv[1:]
expected = 'Привет из контейнера!' if version == '1.0' else 'Привет из контейнера! Версия 1.1.'
url = f'http://127.0.0.1:{port}/'
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
    'url': url,
    'status': status,
    'headers': headers,
    'body': body,
    'version': version,
    'passed': True,
}, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'HTTP check passed: {url} -> {status}; {body}')
PY
    docker logs "$container_id" > "$evidence_dir/logs-$version.txt" 2>&1
    cat -- "$evidence_dir/logs-$version.txt"
done

echo '+ docker images --digests lab-app'
docker images --digests lab-app | tee "$evidence_dir/docker-images.txt"
docker image inspect lab-app:1.0 lab-app:1.1 > "$evidence_dir/images-inspect.json"
docker image inspect --format '{{index .RepoTags 0}} ID={{.Id}} SIZE_BYTES={{.Size}} OS={{.Os}} ARCH={{.Architecture}}' \
    lab-app:1.0 lab-app:1.1 | tee "$evidence_dir/image-sizes.txt"
echo '+ docker ps --no-trunc (containers of this invocation only)'
docker ps --no-trunc --filter "label=com.codex.dockerhub-lab.run=$run_id" \
    | tee "$evidence_dir/docker-ps.txt"
docker container inspect "${container_ids[@]}" > "$evidence_dir/containers-inspect.json"
completed=1
echo 'Local builds and both HTTP checks passed. No Docker Hub publication was performed.'
echo 'Containers remain running for screenshots at host ports 8000 and 8080.'
printf 'After screenshots, stop and remove only these container IDs:\n  docker stop'
printf ' %s' "${container_ids[@]}"
printf '\n  docker rm'
printf ' %s' "${container_ids[@]}"
printf '\n'
