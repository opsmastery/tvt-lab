"""Local series by job on tvt-kps, and how many values-cloud.yaml would send.

Reads the keep and drop regexes from values-cloud.yaml, applies them the way
Prometheus does (full match on job;metrics_path;__name__), and prints the total
against the free-tier budget. Talks to Prometheus through the API server
proxy, so no port-forward is needed.
"""
import json, pathlib, re, subprocess, sys, urllib.parse

CTX = "kind-tvt-kps"
BASE = "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy"
BUDGET = 2500  # tvt-lab's Alloy output uses ~7k of the 10k free tier

def query(expr):
    path = BASE + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    out = subprocess.run(["kubectl", "--context", CTX, "get", "--raw", path],
                         capture_output=True, text=True, timeout=60)
    if out.returncode:
        sys.exit(out.stderr.strip())
    return json.loads(out.stdout)["data"]["result"]

def regexes():
    text = (pathlib.Path(__file__).parent.parent / "values-cloud.yaml").read_text()
    keep = re.search(r"action: keep\n\s+regex: >-\n\s+(.+)\n", text).group(1).strip()
    drop = re.search(r"action: drop\n\s+regex: (.+)\n", text).group(1).strip()
    return re.compile(keep), re.compile(drop)

def main():
    keep, drop = regexes()
    rows = query('count by (job, metrics_path, __name__) ({__name__!=""})')
    total = kept = 0
    by_job, kept_by_job = {}, {}
    for r in rows:
        m, n = r["metric"], int(r["value"][1])
        job = m.get("job", "")
        total += n
        by_job[job] = by_job.get(job, 0) + n
        key = f'{job};{m.get("metrics_path", "")};{m["__name__"]}'
        if keep.fullmatch(key) and not drop.fullmatch(m["__name__"]):
            kept += n
            kept_by_job[job] = kept_by_job.get(job, 0) + n
    print(f"{'job':45} {'local':>7} {'cloud':>7}")
    for job, n in sorted(by_job.items(), key=lambda x: -x[1]):
        print(f"{job or '(rules, ALERTS)':45} {n:7} {kept_by_job.get(job, 0):7}")
    print(f"{'total':45} {total:7} {kept:7}   budget {BUDGET}")
    if kept > BUDGET:
        sys.exit("over budget: tighten values-cloud.yaml")

main()
