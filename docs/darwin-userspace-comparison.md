# Darwin userspace comparison candidate — not enabled or runtime qualified

This opt-in experiment avoids macOS NativeTun using the official Tailscale
1.104.4 binary and action 064b10558093f38325e838ddea35486bdc6b1d5c. It is
not a proved repair for an ENOBUFS error or tailscale/tailscale#21996. The
existing native connection step remains the default; Linux is unaffected.
There is no automatic comparison dispatch.

## Source support and DNS

The official 1.104.4 tailssh server builds for Darwin. Its netstack intercepts
local SSH TCP flows through ShouldInterceptTCPPort, including without a native
TUN. This supports attempting inbound Tailscale SSH; it does not qualify the
leased Mac, runner account, ACL or Nix daemon at runtime.

The pinned action starts tailscaled with the supplied --tun option. Its macOS
DNS helper ignores --accept-dns=false and writes Ethernet DNS/search settings
when MagicDNS is enabled. The candidate saves the prior Ethernet configuration
in a private local file, runs the official action with userspace networking and
SSH, then restores DNS and search settings in an always() step. DHCP settings
are restored with networksetup's Empty value. Public github.com and
cache.nixos.org resolution must pass before the watchdog starts.

There is a short DNS-disruption window between the action's unconditional DNS
write and the restore step. A runner kill in that window prevents restoration.
The official action has no independent skip-DNS input; zero-interruption DNS
preservation cannot be promised without changing that action or tailnet policy.
Neither change is included. This candidate is for disposable hosted Macs only,
not persistent runners. Preexisting 100.100.100.100 settings are rejected rather
than presented as a working public DNS baseline.

The helper is embedded in the workflow so the existing independent helper
checkout pin is untouched. No private environment, tag, ACL, OIDC audience,
admission rule, client or consumer pin changes are included.

## Public-only runtime qualification plan — requires source review first

1. Review this exact candidate and its seven offline tests. Publish through a
   normal owning-repository PR only after approval. Existing PR18 is separate.
2. The current public provider wrapper pins reusable workflow 601d23de and does
   not declare/forward experimental_darwin_userspace. The current nix-remote
   client also does not submit that input. A reviewed public-only caller that
   forwards this flag to the reviewed candidate revision is therefore required
   before an actual comparison can run. Do not silently alter those pins or the
   private environment's exact job_workflow_ref admission rule. Confirm that the
   existing public federation and Niks3 OIDC grants already permit that caller;
   if not, stop and return that exact unsupported claim. No new grants here.
3. Acquire one Mac through that normal public caller with the existing SSH
   identity/tag/ACLs and explicit opt-in. Keep all private inputs absent. Retain
   the run until its normal evidence capture and publication finish; do not
   dispatch a private Flakey graph. Cap acquisition at20min and the command at
   15min; absence of capacity is a capacity outcome, not a failed comparison.
4. Use the existing client admission/key-pinning routine for that exact leased
   node. Test inbound `runner` Tailscale SSH, exact official Tailscale/Nix versions
   and `nix store info --store ssh-ng://... --json` over that same pinned route.
   No accept-new/no-check-sigs or alternate credentials. No manual daemon restart.
5. Instantiate one public aarch64-darwin derivation locally, with /bin/sh as its
   builder and a constant public output. Transfer its derivation over the same
   ssh-ng route and realise it with zero local jobs. Check the resulting bytes
   and expected output path. No Flakey checkout, locked private input or private
   filesystem path is eligible for this fixture.
6. Signal completion on that same pinned route. Require provider success and
   actual Niks3 selected-output publication through the existing OIDC helper.
   A fresh ordinary signature-required consumer substitution of that one public
   output must reproduce its bytes. Do not add a whole-closure cache audit.
7. Record success/failure of DNS restoration, inbound SSH, daemon RPC, public
   input transfer/build, publication and consumer substitution separately.
   Report a pass only for exercised stages; a small public fixture proves this
   path is viable, not that hours-long private graphs are reliable. A longer
   load comparison needs a separately bounded reviewed workload, not blind retries.

## Safe counters

While opted in, the existing watchdog emits at most121 samples, at least60s
apart: integer timestamp, self Online/Running booleans, kern.num_files,
kern.maxfiles, kern.ipc.nmbclusters and parsed mbuf denied/delayed/drain counters.
Each local command is bounded to5s and262144 output characters. Missing counters
are omitted, not zero-filled. No raw tailscale status, peer map, IP address,
hostname, DNS configuration, environment, daemon log or arbitrary stderr is
published. No sysctl writes, packet capture or new diagnostic upload mechanism
is introduced. These counters can indicate pressure, not identify a cancel actor
or establish a kernel/engine failure by themselves.

## Primary source references

- https://raw.githubusercontent.com/tailscale/github-action/064b10558093f38325e838ddea35486bdc6b1d5c/src/main.ts
- https://raw.githubusercontent.com/tailscale/tailscale/v1.104.4/ssh/tailssh/tailssh.go
- https://raw.githubusercontent.com/tailscale/tailscale/v1.104.4/wgengine/netstack/netstack.go
- https://raw.githubusercontent.com/tailscale/tailscale/v1.104.4/cmd/tailscaled/tailscaled.go
