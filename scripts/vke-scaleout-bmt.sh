#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-icn}"
PLAN="${PLAN:-vc2-1c-2gb}"
NODES="${NODES:-4}"
INITIAL_REPLICAS="${INITIAL_REPLICAS:-50}"
FINAL_REPLICAS="${FINAL_REPLICAS:-200}"
LOADGEN_PODS="${LOADGEN_PODS:-200}"
REQUESTS_PER_LOADGEN="${REQUESTS_PER_LOADGEN:-20}"
VERSION="${VERSION:-}"
RUN_ID="${RUN_ID:-vke-bmt-$(date +%Y%m%d%H%M%S)}"
LABEL="${LABEL:-vke-scaleout-${RUN_ID}}"
BASE_DIR="${BASE_DIR:-$(pwd)/runs/${RUN_ID}}"

KUBECTL="${KUBECTL:-$BASE_DIR/kubectl}"
KUBECONFIG_FILE="$BASE_DIR/kubeconfig.yaml"
STATE_FILE="$BASE_DIR/state.env"
REPORT_FILE="$BASE_DIR/report.txt"

mkdir -p "$BASE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$BASE_DIR/driver.log" >&2
}

require_env() {
  [[ -n "${VULTR_API_KEY:-}" ]] || {
    echo "ERROR: VULTR_API_KEY is required" >&2
    exit 1
  }
  [[ "${ALLOW_COSTLY_BMT:-}" == "1" ]] || {
    echo "ERROR: set ALLOW_COSTLY_BMT=1 because this creates billable Vultr resources" >&2
    exit 1
  }
}

auth_header_file() {
  local f="$BASE_DIR/.vultr-auth"
  umask 077
  printf 'Authorization: Bearer %s\n' "$VULTR_API_KEY" >"$f"
  printf '%s\n' "$f"
}

api() {
  local method="$1" path="$2" data="${3:-}" auth
  auth="$(auth_header_file)"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" -H @"$auth" -H 'Content-Type: application/json' --data "$data" "https://api.vultr.com/v2${path}"
  else
    curl -fsS -X "$method" -H @"$auth" "https://api.vultr.com/v2${path}"
  fi
}

state_put() {
  local key="$1" value="$2"
  grep -v "^${key}=" "$STATE_FILE" 2>/dev/null >"$STATE_FILE.tmp" || true
  printf '%s=%q\n' "$key" "$value" >>"$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

state_get() {
  local key="$1"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    eval "printf '%s' \"\${$key:-}\""
  fi
}

ensure_tools() {
  command -v curl >/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }
  command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
  if command -v kubectl >/dev/null; then
    KUBECTL="$(command -v kubectl)"
    return
  fi
  if [[ ! -x "$KUBECTL" ]]; then
    log "kubectl not found; downloading temporary kubectl"
    local stable
    stable="$(curl -fsS https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/${stable}/bin/linux/amd64/kubectl" -o "$KUBECTL"
    chmod +x "$KUBECTL"
  fi
}

kctl() {
  "$KUBECTL" --kubeconfig "$KUBECONFIG_FILE" "$@"
}

select_version() {
  if [[ -n "$VERSION" ]]; then
    printf '%s\n' "$VERSION"
  else
    api GET /kubernetes/versions | jq -r '.versions[0]'
  fi
}

create_cluster() {
  local version payload response id
  version="$(select_version)"
  log "create VKE cluster label=$LABEL region=$REGION version=$version plan=$PLAN nodes=$NODES"
  payload="$(jq -n \
    --arg label "$LABEL" \
    --arg region "$REGION" \
    --arg version "$version" \
    --arg plan "$PLAN" \
    --argjson nodes "$NODES" \
    '{label:$label, region:$region, version:$version, node_pools:[{node_quantity:$nodes, label:"bmt-pool", plan:$plan, auto_scaler:false}]}')"
  response="$(api POST /kubernetes/clusters "$payload")"
  id="$(jq -r '.vke_cluster.id // .id' <<<"$response")"
  [[ -n "$id" && "$id" != "null" ]] || {
    echo "ERROR: VKE cluster id was not returned" >&2
    exit 1
  }
  state_put CLUSTER_ID "$id"
  log "created VKE cluster id=$id"
}

wait_cluster() {
  local id status ready response
  id="$(state_get CLUSTER_ID)"
  for _ in $(seq 1 180); do
    response="$(api GET "/kubernetes/clusters/${id}")"
    status="$(jq -r '.vke_cluster.status // .status // "unknown"' <<<"$response")"
    ready="$(jq -r '[.vke_cluster.node_pools[]?.nodes[]? | select(.status=="active" or .status=="running")] | length' <<<"$response")"
    log "cluster status=$status ready_nodes=$ready/$NODES"
    [[ "$status" == "active" || "$status" == "running" ]] && [[ "$ready" -ge "$NODES" ]] && return 0
    sleep 10
  done
  echo "ERROR: cluster was not ready in time" >&2
  return 1
}

download_kubeconfig() {
  local id response
  id="$(state_get CLUSTER_ID)"
  response="$(api GET "/kubernetes/clusters/${id}/config")"
  jq -r '.kube_config' <<<"$response" | base64 -d >"$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"
}

wait_kubectl() {
  for _ in $(seq 1 120); do
    if kctl get nodes >/dev/null 2>&1; then
      local n
      n="$(kctl get nodes --no-headers | wc -l | tr -d ' ')"
      log "kubectl ready nodes=$n"
      [[ "$n" -ge "$NODES" ]] && return 0
    fi
    sleep 5
  done
  echo "ERROR: kubectl could not reach cluster" >&2
  return 1
}

deploy_web() {
  cat >"$BASE_DIR/web.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-bmt
spec:
  replicas: 0
  selector:
    matchLabels:
      app: web-bmt
  template:
    metadata:
      labels:
        app: web-bmt
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 1m
            memory: 8Mi
          limits:
            cpu: 20m
            memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web-bmt
spec:
  selector:
    app: web-bmt
  ports:
  - port: 80
    targetPort: 80
YAML
  kctl apply -f "$BASE_DIR/web.yaml"
}

wait_web_ready() {
  local replicas="$1" key="$2" start end
  start="$(date +%s)"
  kctl rollout status deployment/web-bmt --timeout=1200s
  kctl wait --for=condition=Ready pod -l app=web-bmt --timeout=1200s
  end="$(date +%s)"
  state_put "$key" "$((end - start))"
}

write_loadgen_job() {
  local name="$1"
  cat >"$BASE_DIR/${name}.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  labels:
    bench: vke-scaleout-bmt
spec:
  parallelism: ${LOADGEN_PODS}
  completions: ${LOADGEN_PODS}
  backoffLimit: 0
  template:
    metadata:
      labels:
        bench: vke-scaleout-bmt
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: curlimages/curl:8.10.1
        command:
        - sh
        - -c
        - |
          ok=0
          fail=0
          total_ms=0
          max_ms=0
          i=1
          while [ "\$i" -le "${REQUESTS_PER_LOADGEN}" ]; do
            start=\$(date +%s%3N)
            code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://web-bmt.default.svc.cluster.local/ || echo 000)
            end=\$(date +%s%3N)
            elapsed=\$((end - start))
            total_ms=\$((total_ms + elapsed))
            [ "\$elapsed" -gt "\$max_ms" ] && max_ms="\$elapsed"
            if [ "\$code" = "200" ]; then ok=\$((ok + 1)); else fail=\$((fail + 1)); fi
            i=\$((i + 1))
          done
          avg_ms=\$((total_ms / ${REQUESTS_PER_LOADGEN}))
          echo "sent=${REQUESTS_PER_LOADGEN} http200=\$ok errors=\$fail avg_ms=\$avg_ms max_ms=\$max_ms"
YAML
}

aggregate_logs() {
  local job="$1" out="$2"
  kctl logs -l "job-name=${job}" --tail=-1 >"$BASE_DIR/${job}.raw.log" 2>/dev/null || true
  awk '
    {
      for (i=1;i<=NF;i++) {
        split($i,a,"=");
        k=a[1]; v=a[2]+0;
        if (k=="sent") sent+=v;
        if (k=="http200") ok+=v;
        if (k=="errors") errors+=v;
        if (k=="avg_ms") { avg_sum+=v; avg_n++; }
        if (k=="max_ms" && v>max_ms) max_ms=v;
      }
    }
    END {
      if (sent == 0) sent=1;
      printf "sent=%d http200=%d errors=%d success_rate=%.1f%% avg_ms=%.1f max_ms=%d\n",
        sent, ok, errors, ok/sent*100, avg_sum/(avg_n?avg_n:1), max_ms;
    }' "$BASE_DIR/${job}.raw.log" | tee "$out"
}

run_loadgen() {
  local name="$1" out="$2"
  write_loadgen_job "$name"
  kctl delete job "$name" --ignore-not-found=true >/dev/null 2>&1 || true
  kctl apply -f "$BASE_DIR/${name}.yaml"
  kctl wait --for=condition=Complete "job/${name}" --timeout=900s
  aggregate_logs "$name" "$out"
}

run_scenario() {
  deploy_web

  log "scale web deployment to $INITIAL_REPLICAS replicas"
  kctl scale deployment/web-bmt --replicas="$INITIAL_REPLICAS"
  wait_web_ready "$INITIAL_REPLICAS" READY_INITIAL_SECONDS

  log "run loadgen against $INITIAL_REPLICAS web pods"
  run_loadgen load-before "$BASE_DIR/metric-before.txt"

  log "scale web deployment to $FINAL_REPLICAS replicas"
  kctl scale deployment/web-bmt --replicas="$FINAL_REPLICAS"
  wait_web_ready "$FINAL_REPLICAS" READY_FINAL_SECONDS

  log "run loadgen against $FINAL_REPLICAS web pods"
  run_loadgen load-after "$BASE_DIR/metric-after.txt"
}

collect_report() {
  {
    echo "run_id=$RUN_ID"
    echo "scenario=one Service URL, ${INITIAL_REPLICAS} web pods under ${LOADGEN_PODS} loadgen pods, then scale to ${FINAL_REPLICAS} web pods"
    echo "provider=Vultr Kubernetes Engine"
    echo "region=$REGION"
    echo "plan=$PLAN"
    echo "nodes=$NODES"
    echo "service_url=http://web-bmt.default.svc.cluster.local/"
    echo "initial_web_pods=$INITIAL_REPLICAS"
    echo "final_web_pods=$FINAL_REPLICAS"
    echo "loadgen_pods=$LOADGEN_PODS"
    echo "requests_per_loadgen=$REQUESTS_PER_LOADGEN"
    echo "ready_initial_seconds=$(state_get READY_INITIAL_SECONDS)"
    echo "ready_final_seconds=$(state_get READY_FINAL_SECONDS)"
    echo
    echo "== before metric =="
    cat "$BASE_DIR/metric-before.txt"
    echo
    echo "== after metric =="
    cat "$BASE_DIR/metric-after.txt"
    echo
    echo "== deployment =="
    kctl get deploy web-bmt -o wide
    echo
    echo "== pod distribution by node =="
    kctl get pods -l app=web-bmt -o wide --no-headers | awk '{c[$7]++} END{for(k in c) print k,c[k]}' | sort
  } | tee "$REPORT_FILE"
}

cleanup() {
  local id
  id="$(state_get CLUSTER_ID 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    log "delete VKE cluster with linked resources: $id"
    api DELETE "/kubernetes/clusters/${id}/delete-with-linked-resources" >/dev/null 2>&1 || \
      api DELETE "/kubernetes/clusters/${id}" >/dev/null 2>&1 || true
  fi
  rm -f "$BASE_DIR/.vultr-auth" || true
}

verify_cleanup() {
  {
    echo "clusters:"
    api GET /kubernetes/clusters | jq -r --arg label "$LABEL" '.vke_clusters[]? | select(.label==$label) | [.id,.label,.status,.region] | @tsv'
    echo "instances:"
    api GET /instances | jq -r --arg label "$LABEL" '.instances[]? | select(.label | contains($label)) | [.id,.label,.status,.power_status] | @tsv'
  } | tee "$BASE_DIR/leftovers.txt"
}

run() {
  require_env
  trap cleanup EXIT
  log "run start label=$LABEL"
  log "cost guard enabled; worker nodes are billable until destroyed"
  ensure_tools
  create_cluster
  wait_cluster
  download_kubeconfig
  wait_kubectl
  run_scenario
  collect_report
  cleanup
  trap - EXIT
  verify_cleanup
  log "done report=$REPORT_FILE"
}

case "${1:-run}" in
  run) run ;;
  cleanup) require_env; cleanup; verify_cleanup ;;
  verify-cleanup) require_env; verify_cleanup ;;
  *) echo "usage: $0 [run|cleanup|verify-cleanup]" >&2; exit 2 ;;
esac
