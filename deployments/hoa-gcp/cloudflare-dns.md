# Cloudflare DNS Setup — auburn-fields.com

## Records to add after GCP VM is running

| Type | Name | Value | Proxy | TTL |
|------|------|-------|-------|-----|
| A | `@` | `<GCP_STATIC_IP>` | Proxied (orange) | Auto |
| A | `www` | `<GCP_STATIC_IP>` | Proxied (orange) | Auto |

Proxied = Cloudflare handles TLS termination. VM only needs port 80 open.

## SSL/TLS Settings (Cloudflare dashboard)

SSL/TLS → Overview → set mode to **Full** (not Full Strict — VM has no cert).

## Page Rules (optional but recommended)

- `http://auburn-fields.com/*` → Always Use HTTPS
- `http://www.auburn-fields.com/*` → Forwarding URL (301) → `https://auburn-fields.com/$1`

## GCP Firewall Rules needed

```bash
gcloud compute firewall-rules create allow-http \
  --allow tcp:80 \
  --target-tags=http-server \
  --description="Allow HTTP from Cloudflare"

# Optional: restrict to Cloudflare IPs only for extra security
# https://www.cloudflare.com/ips/
```

## Verify

After DNS propagates:
1. `curl -I https://auburn-fields.com` → 200 OK
2. WP admin login works at `https://auburn-fields.com/wp-admin`
3. All images load (no mixed content)
