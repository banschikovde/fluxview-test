#!/usr/bin/env bash
# Smoke tests for external GitRepository sources and git-source auth policy.
#
# Covers: file:// upstreams with pinned tags and floating branches, the
# --git-source-cache-dir/-ttl flags, SSH host key policies
# (--git-source-ssh-known-hosts, --git-source-ssh-accept-new) against a
# local sshd fixture, and host scoping of https credentials
# (FLUXVIEW_GIT_CREDENTIAL_HOSTS) against a local always-401 server.
#
# Scenarios needing sshd or python3 are skipped (not failed) when the
# binary is unavailable.

source "$(dirname "${BASH_SOURCE[0]}")/lib/framework.sh"

EXT_TMP="$REPO_ROOT/tests/.tmp/external-sources"
mkdir -p "$EXT_TMP"

# make_ext_upstream <dir>: a bare repository whose config/crds holds a
# Kustomization + one CRD; tag v1.0.0 pins the first revision ("widgets"),
# the branch tip moves the CRD to "gadgets".
make_ext_upstream() {
    local dir=$1
    rm -rf "$dir" "$dir.git"
    mkdir -p "$dir/config/crds"
    git -C "$dir" init -q -b main
    write_ext_crd "$dir" widgets
    cat > "$dir/config/crds/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [crd.yaml]
EOF
    git -C "$dir" add -A
    git -C "$dir" -c user.email=fluxview@test -c user.name=fluxview commit -qm "v1"
    git -C "$dir" tag v1.0.0
    write_ext_crd "$dir" gadgets
    git -C "$dir" add -A
    git -C "$dir" -c user.email=fluxview@test -c user.name=fluxview commit -qm "v2"
    git clone -q --bare "$dir" "$dir.git"
}

write_ext_crd() {
    local dir=$1 kind=$2
    cat > "$dir/config/crds/crd.yaml" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $kind.external.io
EOF
}

# write_ext_cluster <dir> <url> <ref-yaml-block>: cluster directory with a
# Kustomization building config/crds from the external GitRepository.
write_ext_cluster() {
    local dir=$1 url=$2 ref=$3
    rm -rf "$dir"; mkdir -p "$dir"
    cat > "$dir/ext.yaml" <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: {name: ext-crds, namespace: flux-system}
spec:
  url: $url
  ref: $ref
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: ext-crds-ks, namespace: flux-system}
spec:
  sourceRef: {kind: GitRepository, name: ext-crds}
  path: ./config/crds
EOF
}

# ─── file:// external sources and the git source cache ───────────────────

test_ext_file_pinned_tag() {
    local tmp="$EXT_TMP/pinned"
    make_ext_upstream "$tmp/up"
    write_ext_cluster "$tmp/cluster" "file://$tmp/up.git" "{tag: v1.0.0}"
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    assert_exit_code 0 "external file:// source with pinned tag builds"
    assert_stdout_contains "CustomResourceDefinition: widgets.external.io" "pinned tag builds the tagged revision"
    assert_contains "Building flux-system/ext-crds-ks" "stderr names the external KS"
}

test_ext_file_floating_branch() {
    local tmp="$EXT_TMP/floating"
    make_ext_upstream "$tmp/up"
    write_ext_cluster "$tmp/cluster" "file://$tmp/up.git" "{branch: main}"
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    assert_exit_code 0 "external file:// source with floating branch builds"
    assert_stdout_contains "CustomResourceDefinition: gadgets.external.io" "floating branch builds the moved tip"
}

test_ext_file_cache_dir_reused() {
    local tmp="$EXT_TMP/cache"
    make_ext_upstream "$tmp/up"
    write_ext_cluster "$tmp/cluster" "file://$tmp/up.git" "{tag: v1.0.0}"
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    assert_exit_code 0 "first build populates the git source cache"
    if [[ -d "$tmp/cache/data" ]]; then
        pass "cache directory holds content-addressed clones"
    else
        fail "cache directory holds content-addressed clones" "no data/ under $tmp/cache"
    fi
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    assert_exit_code 0 "second build reuses the cached clone"
    assert_stdout_contains "CustomResourceDefinition: widgets.external.io" "cached pinned tag still builds the tagged revision"
}

test_ext_file_cache_ttl_zero_reresolves() {
    local tmp="$EXT_TMP/ttl"
    make_ext_upstream "$tmp/up"
    write_ext_cluster "$tmp/cluster" "file://$tmp/up.git" "{branch: main}"
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache" --git-source-cache-ttl 0
    assert_exit_code 0 "first build with --git-source-cache-ttl 0 succeeds"
    # Move the branch tip: a zero TTL must re-resolve to the new tip.
    write_ext_crd "$tmp/up" "gizmos"
    git -C "$tmp/up" add -A
    git -C "$tmp/up" -c user.email=fluxview@test -c user.name=fluxview commit -qm "v3"
    git -C "$tmp/up.git" fetch -q origin main:main
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache" --git-source-cache-ttl 0
    assert_exit_code 0 "zero TTL re-resolves the floating branch"
    assert_stdout_contains "CustomResourceDefinition: gizmos.external.io" "re-resolution picked up the moved tip"
}

test_ext_file_missing_upstream_warns_and_skips() {
    local tmp="$EXT_TMP/missing"
    make_ext_upstream "$tmp/up"
    write_ext_cluster "$tmp/cluster" "file://$tmp/does-not-exist.git" "{tag: v1.0.0}"
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    assert_exit_code 0 "build warn-and-skips an unreachable external source"
    assert_stderr_contains "failed" "stderr warns about the failed fetch"
    assert_stderr_contains "skipping its resources" "stderr reports the skip"
}

# ─── SSH host key policies (local sshd fixture) ──────────────────────────

SSHD_PID=''

# start_ext_sshd <tmpdir>: starts sshd on 127.0.0.1:<port> serving the
# current user with the generated client key authorized. Sets ext_ssh_url
# and writes known_hosts/empty_known_hosts/client_key under <tmpdir>.
start_ext_sshd() {
    local tmp=$1
    command -v sshd >/dev/null || command -v /usr/sbin/sshd >/dev/null || return 1
    command -v ssh-keyscan >/dev/null || return 1
    local sshd_bin
    sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)

    # Stale keys/known_hosts from an earlier run make ssh-keygen refuse to
    # overwrite; always start from a clean fixture.
    rm -rf "$tmp/host_key" "$tmp/host_key.pub" "$tmp/client_key" \
        "$tmp/client_key.pub" "$tmp/known_hosts" "$tmp/empty_known_hosts" "$tmp/sshd" "$tmp/sshd_config"

    local port
    for port in 47222 47223 47224 47225; do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            break
        fi
        exec 3>&- 3<&- 2>/dev/null || true
        port=''
    done
    [[ -n "$port" ]] || return 1

    ssh-keygen -qt ed25519 -N "" -f "$tmp/host_key" >/dev/null 2>&1 || return 1
    ssh-keygen -qt ed25519 -N "" -f "$tmp/client_key" >/dev/null 2>&1 || return 1
    mkdir -p "$tmp/sshd"
    cp "$tmp/client_key.pub" "$tmp/sshd/authorized_keys"
    cat > "$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/host_key
AuthorizedKeysFile $tmp/sshd/authorized_keys
AuthenticationMethods publickey
PasswordAuthentication no
UseDNS no
StrictModes no
LogLevel ERROR
EOF
    "$sshd_bin" -D -e -f "$tmp/sshd_config" 2>/dev/null &
    SSHD_PID=$!
    sleep 1
    kill -0 "$SSHD_PID" 2>/dev/null || { SSHD_PID=''; return 1; }

    : > "$tmp/empty_known_hosts"
    ssh-keyscan -p "$port" 127.0.0.1 > "$tmp/known_hosts" 2>/dev/null
    ext_ssh_url="ssh://$USER@127.0.0.1:$port"
    ext_ssh_port=$port
    return 0
}

stop_ext_sshd() {
    if [[ -n "$SSHD_PID" ]]; then
        kill "$SSHD_PID" 2>/dev/null || true
        wait "$SSHD_PID" 2>/dev/null || true
        SSHD_PID=''
    fi
}

test_ext_ssh_strict_known_hosts_passes() {
    local tmp="$EXT_TMP/ssh"
    make_ext_upstream "$tmp/up"
    if ! start_ext_sshd "$tmp"; then
        skip "ext_ssh_strict_known_hosts (sshd unavailable)"
        return 0
    fi
    write_ext_cluster "$tmp/cluster" "$ext_ssh_url$tmp/up.git" "{branch: main}"
    export FLUXVIEW_GIT_SSH_KEY="$tmp/client_key"
    run_fluxview build ks --path "$tmp/cluster" \
        --git-source-cache-dir "$tmp/cache" --git-source-ssh-known-hosts "$tmp/known_hosts"
    unset FLUXVIEW_GIT_SSH_KEY
    assert_exit_code 0 "strict known_hosts build over ssh succeeds"
    assert_stdout_contains "CustomResourceDefinition: gadgets.external.io" "ssh fetch built the upstream content"
    assert_not_contains "host key verification failed" "no host key errors with the pinned host key"
    stop_ext_sshd
}

test_ext_ssh_strict_unknown_host_fails() {
    local tmp="$EXT_TMP/ssh-strict"
    make_ext_upstream "$tmp/up"
    if ! start_ext_sshd "$tmp"; then
        skip "ext_ssh_strict_unknown_host (sshd unavailable)"
        return 0
    fi
    write_ext_cluster "$tmp/cluster" "$ext_ssh_url$tmp/up.git" "{branch: main}"
    export FLUXVIEW_GIT_SSH_KEY="$tmp/client_key"
    run_fluxview build ks --path "$tmp/cluster" \
        --git-source-cache-dir "$tmp/cache" --git-source-ssh-known-hosts "$tmp/empty_known_hosts"
    unset FLUXVIEW_GIT_SSH_KEY
    assert_exit_code 0 "build warn-and-skips an untrusted host key"
    assert_stderr_contains "host key verification failed" "strict mode rejects an unknown host key"
    assert_stderr_contains "pass --git-source-ssh-accept-new" "error names the TOFU remedy"
    stop_ext_sshd
}

test_ext_ssh_accept_new_tofu_passes() {
    local tmp="$EXT_TMP/ssh-tofu"
    make_ext_upstream "$tmp/up"
    if ! start_ext_sshd "$tmp"; then
        skip "ext_ssh_accept_new_tofu (sshd unavailable)"
        return 0
    fi
    write_ext_cluster "$tmp/cluster" "$ext_ssh_url$tmp/up.git" "{branch: main}"
    export FLUXVIEW_GIT_SSH_KEY="$tmp/client_key"
    run_fluxview build ks --path "$tmp/cluster" \
        --git-source-cache-dir "$tmp/cache" --git-source-ssh-known-hosts "$tmp/empty_known_hosts" \
        --git-source-ssh-accept-new
    unset FLUXVIEW_GIT_SSH_KEY
    assert_exit_code 0 "accept-new (TOFU) build over ssh succeeds"
    assert_stdout_contains "CustomResourceDefinition: gadgets.external.io" "TOFU fetch built the upstream content"
    assert_not_contains "host key verification failed" "unknown host key accepted on first use"
    stop_ext_sshd
}

# ─── Host scoping of https credentials (always-401 server) ───────────────

HTTP403_PID=''

# start_ext_401_server <port>: python3 HTTP server answering 401 to
# everything, standing in for a private forge that rejects the request.
start_ext_401_server() {
    command -v python3 >/dev/null || return 1
    local port=$1
    python3 - "$port" <<'EOF' &
import http.server, socketserver, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def _deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="fluxview-test"')
        self.end_headers()
        self.wfile.write(b"authentication required")
    do_GET = _deny
    do_POST = _deny
    def log_message(self, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
    HTTP403_PID=$!
    sleep 1
    kill -0 "$HTTP403_PID" 2>/dev/null
}

stop_ext_401_server() {
    if [[ -n "$HTTP403_PID" ]]; then
        kill "$HTTP403_PID" 2>/dev/null || true
        wait "$HTTP403_PID" 2>/dev/null || true
        HTTP403_PID=''
    fi
}

test_ext_https_creds_withheld_for_unlisted_host() {
    local tmp="$EXT_TMP/creds-withheld"
    write_ext_cluster "$tmp/cluster" "http://127.0.0.1:48222/upstream.git" "{branch: main}"
    if ! start_ext_401_server 48222; then
        skip "ext_https_creds_withheld (python3 unavailable)"
        return 0
    fi
    export FLUXVIEW_GIT_TOKEN=glpat-smoke-token
    export FLUXVIEW_GIT_CREDENTIAL_HOSTS=github.com
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    unset FLUXVIEW_GIT_TOKEN FLUXVIEW_GIT_CREDENTIAL_HOSTS
    assert_exit_code 0 "build warn-and-skips when credentials are withheld"
    assert_stderr_contains "not allowed for this host" "failure names the host allowlist"
    assert_stderr_contains "FLUXVIEW_GIT_CREDENTIAL_HOSTS" "remedy mentions FLUXVIEW_GIT_CREDENTIAL_HOSTS"
    assert_not_contains "glpat-smoke-token" "the token value never appears anywhere"
    stop_ext_401_server
}

test_ext_https_creds_sent_to_listed_host() {
    local tmp="$EXT_TMP/creds-listed"
    write_ext_cluster "$tmp/cluster" "http://127.0.0.1:48222/upstream.git" "{branch: main}"
    if ! start_ext_401_server 48222; then
        skip "ext_https_creds_listed (python3 unavailable)"
        return 0
    fi
    export FLUXVIEW_GIT_TOKEN=glpat-smoke-token
    export FLUXVIEW_GIT_CREDENTIAL_HOSTS=127.0.0.1
    run_fluxview build ks --path "$tmp/cluster" --git-source-cache-dir "$tmp/cache"
    unset FLUXVIEW_GIT_TOKEN FLUXVIEW_GIT_CREDENTIAL_HOSTS
    assert_exit_code 0 "build warn-and-skips a rejecting upstream for a listed host"
    # Credentials traveled to the listed host and were rejected: the plain
    # bad-credentials remedy, not the allowlist one.
    assert_stderr_contains "private repository or bad credentials" "listed host gets the plain bad-credentials message"
    assert_not_contains "not allowed for this host" "credentials were not withheld for the listed host"
    stop_ext_401_server
}

trap 'stop_ext_sshd; stop_ext_401_server' EXIT

# ─── Registration ────────────────────────────────────────────────────────

test_case "ext_file_pinned_tag"                 test_ext_file_pinned_tag
test_case "ext_file_floating_branch"            test_ext_file_floating_branch
test_case "ext_file_cache_dir_reused"           test_ext_file_cache_dir_reused
test_case "ext_file_cache_ttl_zero_reresolves"  test_ext_file_cache_ttl_zero_reresolves
test_case "ext_file_missing_upstream_warns"     test_ext_file_missing_upstream_warns_and_skips
test_case "ext_ssh_strict_known_hosts"          test_ext_ssh_strict_known_hosts_passes
test_case "ext_ssh_strict_unknown_host"         test_ext_ssh_strict_unknown_host_fails
test_case "ext_ssh_accept_new_tofu"             test_ext_ssh_accept_new_tofu_passes
test_case "ext_https_creds_withheld"            test_ext_https_creds_withheld_for_unlisted_host
test_case "ext_https_creds_listed"              test_ext_https_creds_sent_to_listed_host
