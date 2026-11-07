#!/usr/bin/env bash
# The SBOMs and Trivy's result of YT Cluster, in its public repository (this one,
# security/), which dbinvent.com links - Schema Guard writes its own since 2026-10-31.
# nightly.sh sources this, calls security_gate between the release build and the
# publish, and security_reports after a green run; by hand:
#
#   nightly/security.sh          # now: the source here and the image as published
#
# Settings: YX_HOST (../.env), the docker host Trivy's container runs on.

# [sbom] YT Cluster's software bills of materials, CycloneDX, and Trivy's result, in its
# public repository (here, security/), which dbinvent.com links (owner, 2026-10-29);
# Schema Guard's are its own to write (owner, 2026-10-31). After a green run, whatever it published: the
# crates of the source this run tested (Cargo.lock, as Trivy reads it) and the image as
# Docker Hub serves it now (its OS packages). Written for a commit, as results.yaml is
# (NIGHTLY_PUSH=1 takes this repository's along). Trivy runs in a container of its own on
# the nightly's docker host, pinned by digest (trivy's tags, March 2026), the lock file
# streamed in. One that fails is a WARN.
TRIVY_IMAGE="aquasec/trivy:0.69.3@sha256:bcc376de8d77cfe086a917230e818dc9f8528e3c852f7b1aff648949b6258d1c"
# where it runs: the nightly's docker host (YX_HOST), never this one
trivy_docker() { case "${YX_HOST:-local}" in local) echo "unix:///var/run/docker.sock" ;; *) echo "ssh://$YX_HOST" ;; esac; }
trivy_crates() { # <dir holding Cargo.lock> <trivy fs args...>: on its lock file, to stdout
	local dir="$1"; shift
	tar -C "$dir" -c Cargo.lock | DOCKER_HOST="$(trivy_docker)" docker run -i --rm --entrypoint sh "$TRIVY_IMAGE" \
		-c 'mkdir -p /src && tar -x -C /src && exec trivy fs --quiet "$@" /src' trivy "$@"
}
trivy_image() { # <image> <trivy image args...>: as the registry serves it, to stdout
	local img="$1"; shift
	DOCKER_HOST="$(trivy_docker)" docker run --rm "$TRIVY_IMAGE" image --quiet --image-src remote "$@" "$img"
}
to_file() { # <out> <command...>: the command's stdout into <out>, only when it made some
	local out="$1"; shift
	"$@" > "$out.tmp" && [ -s "$out.tmp" ] && mv "$out.tmp" "$out" || { rm -f "$out.tmp"; return 1; }
}
security_report() { # <name> <title> <repo dir> <source dir> <image>
	local name="$1" title="$2" dir="$3/security" src="$4" img="$5" bad=0 md crates image
	mkdir -p "$dir" || { echo "  WARN  security: no $dir"; return 1; }
	to_file "$dir/sbom-$name.cdx.json" trivy_crates "$src" --format cyclonedx || bad=1
	to_file "$dir/sbom-$name-image.cdx.json" trivy_image "$img" --format cyclonedx || bad=1
	# every severity counted; the rows, CRITICAL and HIGH only - the base image's LOW ones
	# alone made a page GitHub would not show (the SBOMs, and the Security tab, hold all)
	crates="$(trivy_crates "$src" --scanners vuln --format table --table-mode summary 2>&1)
$(trivy_crates "$src" --scanners vuln --format table --severity CRITICAL,HIGH 2>&1)" || bad=1
	image="$(trivy_image "$img" --scanners vuln --format table --table-mode summary 2>&1)
$(trivy_image "$img" --scanners vuln --format table --severity CRITICAL,HIGH 2>&1)" || bad=1
	md="$dir/trivy-$name.md"
	{
		echo "# Trivy: $title"
		echo
		echo "The nightly's scan (yt-cluster-tests nightly/nightly.sh, \`security_report\`), run $RUN_ID, $(date -u +'%Y-%m-%d %H:%M') UTC:"
		echo "Trivy $(echo "$TRIVY_IMAGE" | sed -E 's/^[^:]+:([^@]+).*/\1/') on $title's crates - the lock file of the source the run tested - and on the"
		echo "image \`$img\` as Docker Hub serves it: every known vulnerability counted by severity, the CRITICAL"
		echo "and HIGH ones listed."
		echo
		echo "Software bills of materials, CycloneDX: [sbom-$name.cdx.json](sbom-$name.cdx.json) (the crates),"
		echo "[sbom-$name-image.cdx.json](sbom-$name-image.cdx.json) (the image)."
		echo
		echo "## The crates"
		echo
		echo '```text'; printf '%s\n' "${crates:-no result}"; echo '```'
		echo
		echo "## The image \`$img\`"
		echo
		echo '```text'; printf '%s\n' "${image:-no result}"; echo '```'
	} > "$md.tmp" && mv "$md.tmp" "$md" || bad=1
	[ "$bad" = 0 ] && echo "  OK    security: $name - SBOMs and Trivy's result in $dir" \
		|| echo "  WARN  security: $name - not every part made ($dir)"
}
# [security-gate] Before anything of a run is published (owner, 2026-11-07): what it is
# to publish, checked as the daily Trivy workflow checks the image Docker Hub serves -
# a HIGH or CRITICAL finding with a fix stops the publish. Three checks, each run
# whatever the others found: the crates of the tested source (Trivy on its Cargo.lock);
# ytserv's tree audited and its own crates unsafe-free (safety_badge.py --gate: a high
# or critical advisory, unsafe code, or a check that could not run); the image of this
# run's deb, built from it on the build host (ytcluster_dist docker/publish.sh DEB=,
# PUSH=0), smoke-checked and scanned there (docker/check.sh) - the image pushed later
# is apt's, checked the same way before its push. Findings accepted: ../.trivyignore,
# each with why. The vulnerability database: a volume on each docker host.
security_gate() { # <deb>
	local deb="$1" bad=0
	if tar -c -C "$YT_PGXT" Cargo.lock -C "$TESTS" .trivyignore | DOCKER_HOST="$(trivy_docker)" docker run -i --rm \
		-v yt-trivy-cache:/root/.cache/trivy --entrypoint sh "$TRIVY_IMAGE" -c 'mkdir -p /src && tar -x -C /src \
		&& exec trivy fs --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
		--ignorefile /src/.trivyignore /src'; then
		echo "  OK    security: the crates - no HIGH or CRITICAL finding with a fix (Trivy, Cargo.lock)"
	else
		echo "  FAIL  security: the crates - a HIGH or CRITICAL finding with a fix, or Trivy did not run (above)"; bad=1
	fi
	if YT_PGXT="$YT_PGXT" python3 "$HERE/safety_badge.py" --gate; then
		echo "  OK    security: ytserv's tree audited, its own crates unsafe-free (safety_badge.py)"
	else
		echo "  FAIL  security: ytserv - a high or critical advisory, unsafe code, or a check that did not run (above)"; bad=1
	fi
	if PUSH=0 DEB="$deb" IMAGE=yt-gate/yt REPO_DIR="$REPO_DIR" INFRA_APT="$INFRA_APT" TRIVY_GATE=1 \
		TRIVY_IMAGE="$TRIVY_IMAGE" TRIVY_IGNORE="$TESTS/.trivyignore" "$DIST/docker/publish.sh" "$DEB_V"; then
		echo "  OK    security: the image of this deb - built, started, no HIGH or CRITICAL finding with a fix"
	else
		echo "  FAIL  security: the image of this deb (docker/publish.sh, above)"; bad=1
	fi
	# never pushed: it goes
	docker rmi "yt-gate/yt:$DEB_V" "yt-gate/yt:${DEB_V%.*}" yt-gate/yt:latest >/dev/null 2>&1 || true
	return "$bad"
}
security_reports() {
	security_report yt-cluster "YT Cluster" "$TESTS" "$YT_PGXT" dbinvent/yt:latest
	# sge's are its own to write, not the nightly's (owner, 2026-10-31)
	return 0
}

# by hand: the settings, then the report
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	set -uo pipefail
	HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	TESTS="$(cd "$HERE/.." && pwd)"
	GIT_ROOT="$(cd "$TESTS/.." && pwd)"
	if [ -f "$TESTS/.env" ]; then
		_keep="$(export -p)"; set -a; . "$TESTS/.env"; set +a; eval "$_keep"; unset _keep
	fi
	YT_PGXT="${YT_PGXT:-$GIT_ROOT/yt-cluster}"
	RUN_ID="by hand"
	security_reports
fi
