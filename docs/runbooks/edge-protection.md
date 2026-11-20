# Edge protection runbook

How traffic is filtered before it reaches an app, and where each rule lives. Goal: one place per
concern, nothing configured per app unless the app genuinely differs.

```
Internet ─▶ Cloudflare (WAF rule)  ─▶ pfSense WAN 80/443 (Cloudflare-only alias) ─▶ Traefik (192.168.1.61)
LAN      ─────────────────────────── Pi-hole split-horizon DNS ───────────────────▶ Traefik
```

| Concern | Where | File / place |
|---|---|---|
| HTTP → HTTPS redirect | Traefik `web` entrypoint | `kubernetes/system/traefik/values.yml` |
| Probe-path blocking (`/.env`, `/.git`, xmlrpc…) | Traefik, host-less route, all hostnames | `kubernetes/system/traefik/middlewares.yml` (`block-probes`) **and** Cloudflare WAF rule below |
| Baseline headers (nosniff, strip X-Powered-By) | Traefik `websecure` entrypoint middleware | `middlewares.yml` (`global-headers`) |
| LAN-only apps | shared `lan-only` middleware | `middlewares.yml`; used by grafana, loki, n8n, traefik dashboard, hoa staging, and (own copy) porquinho |
| Direct-to-origin lockout | pfSense NAT rule | manual, below |
| JSON access logs | Traefik | `values.yml` (`logs.access`) — headers are dropped, so no Authorization/cookies logged |

## Apply order / commands

```bash
kubectl apply -f kubernetes/system/traefik/middlewares.yml        # first: values.yml references it
helm upgrade --install traefik traefik/traefik -n traefik \
  --version 39.0.6 -f kubernetes/system/traefik/values.yml --wait # rolling, maxUnavailable 0
```

Rollback: `helm rollback traefik <rev> -n traefik` (rev 4 = before this change), then
`kubectl delete -f kubernetes/system/traefik/middlewares.yml` and remove the `lan-only`
references from the five IngressRoutes.

## Add a new app

- **Public (via Cloudflare):** nothing to add — block-probes, headers and HTTPS redirect already apply.
- **LAN-only:** add to its route `middlewares: [{name: lan-only, namespace: traefik}]`.
  Do not create a new allow-list middleware.

## Blocked path list (single source)

Edit the regex in `middlewares.yml`, then mirror it in the Cloudflare rule. Currently:
dot-files/dirs `.env* .git* .svn .hg .aws .azure .ssh .docker .kube .npmrc .htaccess .htpasswd
.DS_Store .bash_history .claude .cursor .anthropic .openai .vscode .idea .gcloud .terraform`,
`/xmlrpc.php`, `wp-config.php` backup copies. **Not** `/.well-known` (Immich/Nextcloud discovery).
Traefik excludes `/remote.php` and `/public.php` (Nextcloud WebDAV file names) — keep that
exclusion in the Cloudflare rule for the `tmf-solutions.com` zone.

## Cloudflare WAF custom rule (manual, free plan)

Dashboard → the zone → Security → WAF → Custom rules → Create rule. Action: **Block**.
Free plan has no regex operator (`matches`), so the rule uses `contains`. Create it in **both**
zones (`auburn-fields.com`, `tmf-solutions.com`). Switch the editor to "Edit expression" and paste.

`auburn-fields.com` (WordPress only, no WebDAV exclusion needed):

```
(lower(http.request.uri.path) contains "/.env") or
(lower(http.request.uri.path) contains "/.git") or
(lower(http.request.uri.path) contains "/.svn") or
(lower(http.request.uri.path) contains "/.hg") or
(lower(http.request.uri.path) contains "/.aws") or
(lower(http.request.uri.path) contains "/.azure") or
(lower(http.request.uri.path) contains "/.ssh") or
(lower(http.request.uri.path) contains "/.docker") or
(lower(http.request.uri.path) contains "/.kube") or
(lower(http.request.uri.path) contains "/.npmrc") or
(lower(http.request.uri.path) contains "/.htaccess") or
(lower(http.request.uri.path) contains "/.htpasswd") or
(lower(http.request.uri.path) contains "/.ds_store") or
(lower(http.request.uri.path) contains "/.bash_history") or
(lower(http.request.uri.path) contains "/.claude") or
(lower(http.request.uri.path) contains "/.cursor") or
(lower(http.request.uri.path) contains "/.anthropic") or
(lower(http.request.uri.path) contains "/.openai") or
(lower(http.request.uri.path) contains "/.vscode") or
(lower(http.request.uri.path) contains "/.idea") or
(lower(http.request.uri.path) contains "/.gcloud") or
(lower(http.request.uri.path) contains "/.terraform") or
(lower(http.request.uri.path) contains "/xmlrpc.php") or
(lower(http.request.uri.path) contains "/wp-config.php.") or
(lower(http.request.uri.path) contains "/wp-config.bak") or
(lower(http.request.uri.path) contains "/wp-config.old")
```

`tmf-solutions.com` (drive/photos): use the same list wrapped as
`( <list above> ) and not starts_with(http.request.uri.path, "/remote.php") and not starts_with(http.request.uri.path, "/public.php")`.

Optional second layer on `auburn-fields.com` (free plan allows 1 rate-limit rule): rate-limit
`/wp-login.php` per IP (e.g. 5 requests / 10 s → block 10 min).

## pfSense: lock WAN 80/443 to Cloudflare (manual)

1. Firewall → Aliases → **URLs** → Add: name `CF_IPv4`, type *URL Table (IPs)*,
   URL `https://www.cloudflare.com/ips-v4`, update frequency 1 day. (Auto-refreshes; no stale list.)
2. Firewall → NAT → Port Forward: edit the WAN **80** and **443** rules → Source → *Address or Alias*
   → `CF_IPv4`. Keep "Filter rule association" on *Pass* so the linked firewall rule follows.
3. Do **not** touch LAN rules. LAN clients reach Traefik directly through Pi-hole, not the WAN rule.
4. Verify from a phone on mobile data (not the LAN):
   - `curl -sk -m 8 https://136.38.86.123/ -o /dev/null -w '%{http_code}'` → must time out (000).
   - `https://auburn-fields.com`, `https://photos.tmf-solutions.com` → still load.
5. Rollback: set the rule Source back to *any*.

Only works while every internet-facing hostname is orange-cloud (true as of 2026-11-20:
apex, www, drive, photos on both zones). A new grey-cloud record would be unreachable from the
internet — by design.

After step 4 is confirmed you can drop `hoa-origin-protection` (hoa namespace): it duplicates
this lockout with a hand-copied Cloudflare range list that goes stale.

## Verify (from the LAN)

```bash
# blocked → 403
curl -sk -o /dev/null -w '%{http_code}\n' --resolve auburn-fields.com:443:192.168.1.61 https://auburn-fields.com/.env
# must NOT be blocked (discovery + WebDAV)
curl -sk -o /dev/null -w '%{http_code}\n' --resolve photos.tmf-solutions.com:443:192.168.1.61 https://photos.tmf-solutions.com/.well-known/immich
# redirect has no :8443 and keeps the path
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve grafana.tmf-solutions.com:80:192.168.1.61 'http://grafana.tmf-solutions.com/x?y=1'
```
