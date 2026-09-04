#!/usr/bin/env bash

set -uo pipefail

if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker CLI is not installed.\n' >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    printf 'Docker daemon is unavailable.\n' >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    printf 'The Docker Compose plugin is not installed.\n' >&2
    exit 1
fi

if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
    printf 'Docker image update preflight passed; mutations are skipped during trial updates.\n'
    exit 0
fi

mapfile -t container_ids < <(docker ps --all --quiet)
if ((${#container_ids[@]} == 0)); then
    printf 'No containers are defined; no images require updates.\n'
    exit 0
fi

projects=()
unmanaged=()
for container_id in "${container_ids[@]}"; do
    details=$(docker inspect --format \
        '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
        "$container_id") || {
        printf '%s: inspection failed.\n' "$container_id" >&2
        exit 1
    }
    IFS='|' read -r name project working_dir config_files <<<"$details"
    name=${name#/}

    if [[ -z "$project" || "$project" == "<no value>" ]]; then
        unmanaged+=("$name")
        continue
    fi
    projects+=("$project|$working_dir|$config_files")
done

if ((${#unmanaged[@]} > 0)); then
    printf 'These containers are not managed by Docker Compose and cannot be safely recreated: %s\n' \
        "${unmanaged[*]}" >&2
    exit 1
fi

mapfile -t unique_projects < <(printf '%s\n' "${projects[@]}" | sort --unique)
for project_record in "${unique_projects[@]}"; do
    IFS='|' read -r project working_dir config_files <<<"$project_record"
    if [[ ! -d "$working_dir" ]]; then
        printf '%s: Compose working directory does not exist: %s\n' "$project" "$working_dir" >&2
        exit 1
    fi

    compose_args=(--project-name "$project" --project-directory "$working_dir")
    IFS=',' read -ra project_files <<<"$config_files"
    for project_file in "${project_files[@]}"; do
        [[ "$project_file" == /* ]] || project_file="$working_dir/$project_file"
        if [[ ! -f "$project_file" ]]; then
            printf '%s: Compose file does not exist: %s\n' "$project" "$project_file" >&2
            exit 1
        fi
        compose_args+=(--file "$project_file")
    done

    printf 'Pulling images for Compose project %s.\n' "$project"
    docker compose "${compose_args[@]}" pull
    printf 'Recreating Compose project %s with updated images.\n' "$project"
    docker compose "${compose_args[@]}" up --detach
done

printf 'Updated %d Docker Compose project(s).\n' "${#unique_projects[@]}"
