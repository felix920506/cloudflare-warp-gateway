# Cloudflare WARP gateway (Docker)

A container that sits on your LAN with **its own IP address** and acts as a router.
Any device that uses that IP as its default gateway has its traffic sent through
**Cloudflare WARP** instead of your normal internet connection.

- Runs entirely in Docker, in its own network namespace (macvlan/ipvlan). The host's
  network setup and routes are not changed.
- WARP connection via WireGuard. Uses kernel WireGuard when available, otherwise
  `wireguard-go` in userspace. The WARP account is registered automatically with
  [wgcf](https://github.com/ViRb3/wgcf) and saved in `./data`.
- **Optional kill switch** (`KILL_SWITCH`, default `false`):
  - `false`: if WARP goes down, client traffic falls back to the normal internet
    connection. When WARP recovers, traffic goes back through WARP automatically.
  - `true`: if WARP goes down, client traffic is blocked until WARP is back.
- Optional DNS forwarder on the gateway IP that resolves through WARP (`ENABLE_DNS`).

## Setup

```sh
cp .env.example .env     # set PARENT_INTERFACE, LAN_SUBNET, LAN_ROUTER, GATEWAY_IP
docker compose up -d --build
docker logs -f warp-gateway
```

`GATEWAY_IP` must be a free address on your LAN, outside the router's DHCP pool.

## Using it

On any client (or in a DHCP reservation on your router):

- **Gateway:** `GATEWAY_IP`
- **DNS:** `GATEWAY_IP` (if `ENABLE_DNS=true`). Otherwise use any public resolver.
  If clients keep using the router as their DNS server, DNS lookups won't go
  through WARP.

**Phones:** iOS and Android only let you set a router when "Configure IP" is set
to Manual (static). In that mode they don't get DNS from DHCP, so you must also
enter a DNS server by hand (`GATEWAY_IP`). Otherwise the phone shows "no internet".
You'll also need to fill in IP address, subnet mask (255.255.255.0) and router.

Check from the client: `curl https://www.cloudflare.com/cdn-cgi/trace` should show `warp=on`.

## How it works

| Piece | What it does |
|---|---|
| `wg0` | WireGuard tunnel to WARP. Its own UDP packets carry fwmark 51820 and leave through the LAN. |
| Policy routing | Unmarked traffic, both forwarded from clients and local, uses table 51820 (`default dev wg0`). LAN destinations stay local. |
| NAT | Masquerade out of `wg0`, and out of the LAN interface when failing over. MSS clamping for MTU 1280. |
| Health check | Every `HEALTH_INTERVAL`s, a probe user that always routes through `wg0` fetches `https://1.1.1.1/cdn-cgi/trace` and expects `warp=on`. After `HEALTH_FAILURES` failures in a row, WARP counts as down. |
| Failover (kill switch off) | Adds an `ip rule` to the direct table (LAN router). It is removed when WARP recovers. Conntrack is flushed when switching. |
| Kill switch on | Drops LAN→LAN forwarding and keeps a blackhole default route in the WARP table. Traffic can't leak even if `wg0` disappears. |

Docker's health status is `healthy` only while traffic is actually going through WARP.

## Notes

- **The host can't reach the gateway.** This is a normal macvlan limitation and is
  expected here, because the host doesn't use the gateway.
- **IPv4 only.** Clients that also have IPv6 from your router will still send IPv6
  traffic directly. Turn off IPv6 on those clients if you need everything to go
  through WARP.
- **Wi-Fi parent interfaces** usually reject extra MAC addresses. Set `LAN_DRIVER=ipvlan`.
- **Performance:** run `sudo modprobe wireguard` on the host (and add it to
  `/etc/modules-load.d/`) so the kernel implementation is used. The logs show which one is active.
- **WARP+:** set `WARP_LICENSE_KEY`. To get a fresh WARP identity, stop the container and delete `./data`.
