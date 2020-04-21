#!/usr/bin/env bash
set -Eeuo pipefail

image="${GITHUB_REPOSITORY##*/}" # "python", "golang", etc

[ -x ./generate-stackbrew-library.sh ] # sanity check

tmp="$(mktemp -d)"
trap "$(printf 'rm -rf %q' "$tmp")" EXIT

# just to be safe
unset "${!BASHBREW_@}"

if ! command -v bashbrew &> /dev/null; then
	echo 'Downloading bahbrew ...'
	mkdir "$tmp/bin"
	wget -qO "$tmp/bin/bashbrew" 'https://doi-janky.infosiftr.net/job/bashbrew/lastSuccessfulBuild/artifact/bin/bashbrew-amd64'
	chmod +x "$tmp/bin/bashbrew"
	export PATH="$tmp/bin:$PATH"
	bashbrew --help > /dev/null
fi

mkdir "$tmp/library"
export BASHBREW_LIBRARY="$tmp/library"

./generate-stackbrew-library.sh > "$BASHBREW_LIBRARY/$image"

tags="$(bashbrew list --build-order --uniq "$image")"

# see https://github.com/docker-library/python/commit/6b513483afccbfe23520b1f788978913e025120a for the ideal of what this would be (minimal YAML in all 30+ repos, shared shell script that outputs fully dynamic steps list), if GitHub Actions were to support a fully dynamic steps list

order=()
declare -A metas=()
for tag in $tags; do
	echo "Processing $tag ..."
	meta="$(
		bashbrew cat --format '
			{{- $e := .TagEntry -}}
			{{- "{" -}}
				"name": {{- json ($e.Tags | first) -}},
				"tags": {{- json ($.Tags "" false $e) -}},
				"directory": {{- json $e.Directory -}},
				"file": {{- json $e.File -}},
				"constraints": {{- json $e.Constraints -}}
			{{- "}" -}}
		' "$tag" | jq -c '
			{
				name: .name,
				os: (
					if (.constraints | contains(["windowsservercore-1809"])) or (.constraints | contains(["nanoserver-1809"])) then
						"windows-2019"
					elif .constraints | contains(["windowsservercore-ltsc2016"]) then
						"windows-2016"
					elif .constraints == [] or .constraints == ["aufs"] then
						"ubuntu-latest"
					else
						# use an intentionally invalid value so that GitHub chokes and we notice something is wrong
						"invalid-or-unknown"
					end
				),
				runs: {
					build: (
						[
							"docker build"
						]
						+ (
							.tags
							| map(
								"--tag " + (. | @sh)
							)
						)
						+ if .file != "Dockerfile" then
							[ "--file", (.file | @sh) ]
						else
							[]
						end
						+ [
							(.directory | @sh)
						]
						| join(" ")
					),
					history: ("docker history " + (.tags[0] | @sh)),
					test: ("~/oi/test/run.sh " + (.tags[0] | @sh)),
				},
			}
		'
	)"

	parent="$(bashbrew parents "$tag" | tail -1)" # if there ever exists an image with TWO parents in the same repo, this will break :)
	if [ -n "$parent" ]; then
		parent="$(bashbrew list --uniq "$parent")" # normalize
		parentMeta="${metas["$parent"]}"
		parentMeta="$(jq -c --argjson meta "$meta" '
			. + {
				name: (.name + $meta.name),
				runs: (
					.runs
					| to_entries
					| map(
						.value += "\n" + $meta.runs[.key]
					)
					| from_entries
				),
			}
		' <<<"$parentMeta")"
		metas["$parent"]="$parentMeta"
	else
		metas["$tag"]="$meta"
		order+=( "$tag" )
	fi
done

strategy="$(
	for tag in "${order[@]}"; do
		jq -c '
			.runs += {
				prepare: ([
					"git clone --depth 1 https://github.com/docker-library/official-images.git ~/oi",
					"# create a dummy empty image/layer so we can --filter since= later to get a meanginful image list",
					"{ echo FROM " + (
						if (.os | startswith("windows-")) then
							"mcr.microsoft.com/windows/servercore:ltsc" + (.os | ltrimstr("windows-"))
						else
							"busybox:latest"
						end
					) + "; echo RUN :; } | docker build --no-cache --tag image-list-marker -"
				] | join("\n")),
				phe: ([
					"git clone --depth 1 https://github.com/tianon/pgp-happy-eyeballs.git ~/phe",
					"~/phe/hack-my-builds.sh",
					"rm -rf ~/phe"
				] | join("\n")),
				images: "docker image ls --filter since=image-list-marker",
			}
		' <<<"${metas["$tag"]}"
	done | jq -cs '
		{
			"fail-fast": false,
			matrix: { include: . },
		}
	'
)"

if [ "${GITHUB_ACTIONS:-}" = 'true' ]; then
	echo "::set-output name=strategy::$strategy"
else
	jq <<<"$strategy"
fi
