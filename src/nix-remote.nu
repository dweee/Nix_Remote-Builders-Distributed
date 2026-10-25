# Helper to assert external command prerequisites
def check-cmd [cmd: closure, msg: string] {
    let res = try {
        do $cmd | complete
    } catch { {exit_code: 1} }
    if $res.exit_code != 0 {
        print --stderr $msg
        exit 1
    }
}

# Base64-encode the host key recorded in a known_hosts file, for a Nix machine spec.
def host-key-b64 [file: path]: nothing -> string {
    let content = try { open --raw $file } catch { "" }
    let entries = ($content
        | lines
        | each {|l| $l | str trim | split row " " }
        | where ($it | length) >= 3)
    if ($entries | is-empty) {
        return "-"
    }
    let entry = $entries | first
    $"($entry.1?) ($entry.2?)" | encode base64
}

# First non-empty string among the candidates, or null.
def first-set [candidates: list<any>]: nothing -> any {
    $candidates | where {|c| $c != null and ($c | into string | str length) > 0 } | get 0?
}

def config-file []: nothing -> string {
    let xdg_config = (
        $env.XDG_CONFIG_HOME?
        | default (
            $env.HOME?
            | default "~"
            | path expand
            | path join ".config"
        )
    )
    $xdg_config | path join "nix-remote" "config.toml"
}

def read-toml [file: path]: nothing -> record {
    if ($file | path exists) {
        try { open $file } catch { {} }
    } else {
        {}
    }
}

# System defaults (written by the NixOS/nix-darwin module), overridden per user.
def load-config []: nothing -> record {
    let system_file = $env.NIX_REMOTE_SYSTEM_CONFIG? | default "/etc/nix-remote/config.toml"
    read-toml $system_file | merge (read-toml (config-file))
}

# Resolve repo, environment, tags and machines file from flags, environment and config.toml.
def resolve-settings [
    repo
    environment
    tailscale_tags
    machines_file
]: nothing -> record {
    let config = load-config
    let config_file = config-file

    let target_repo = (first-set [
        $repo
        ($config | get --optional repo)
    ])
    let target_repo = if $target_repo != null {
        $target_repo
    } else {
        let detected = gh repo view --json nameWithOwner -q .nameWithOwner | complete
        if $detected.exit_code == 0 and ($detected.stdout | str trim | is-not-empty) {
            $detected.stdout | str trim
        } else {
            let git_url = if (which git | is-not-empty) {
                (git remote get-url origin | complete)
            } else {
                {exit_code: 1, stdout: ""}
            }
            if $git_url.exit_code == 0 and ($git_url.stdout | str trim | is-not-empty) {
                $git_url.stdout | str trim
            } else {
                print --stderr $"Error: No runner repository specified.\nPlease configure a repository in '($config_file)', use --repo <owner/repo>, or run from inside a git repository."
                exit 1
            }
        }
    }

    let runtime_dir = $env.XDG_RUNTIME_DIR? | default (
        $env.HOME?
        | default "~"
        | path expand
        | path join ".local" "state"
    )
    {
        repo: $target_repo
        environment: (first-set [
            $environment
            ($config | get --optional environment)
        ])
        tags: (
            first-set [
                $tailscale_tags
                ($config | get --optional tailscale_tags)
                "tag:nix-builder"
            ]
        )
        machines_file: (first-set [
            $machines_file
            $env.NIX_REMOTE_MACHINES_FILE?
            ($config | get --optional machines_file)
            ($runtime_dir | path join "nix-remote" "machines")
        ])
    }
}

# Builder counts from explicit flags, or null when none were given.
def explicit-counts [
    runners
    x86
    arm
    darwin
]: nothing -> any {
    if $x86 != null or $arm != null or $darwin != null {
        {
            x86: ($x86 | default 0)
            arm: ($arm | default 0)
            darwin: ($darwin | default 0)
        }
    } else if $runners != null {
        {x86: $runners, arm: 0, darwin: 0}
    } else {
        null
    }
}

# One builder of this machine's own system, used when nothing could be evaluated.
def default-counts []: nothing -> record {
    let arch = $nu.os-info.arch
    if $nu.os-info.name == "macos" {
        {x86: 0, arm: 0, darwin: 1}
    } else if $arch == "aarch64" {
        {x86: 0, arm: 1, darwin: 0}
    } else {
        {x86: 1, arm: 0, darwin: 0}
    }
}

# Scale builder counts to the systems of the derivations that need building.
def scale-counts [systems: list<string>, max_runners: int]: nothing -> record {
    let x86_unbuilt = $systems | where $it in ["x86_64-linux" "i686-linux"] | length
    let arm_unbuilt = $systems | where $it == "aarch64-linux" | length
    let darwin_unbuilt = $systems | where $it == "aarch64-darwin" | length

    let scale_for = {|count: int|
        if $count <= 0 { 0 } else if $count <= 1 { 1 } else if $count <= 4 { 2 } else if $count <= 8 { 3 } else { $max_runners }
    }

    mut x86_cnt = (do $scale_for $x86_unbuilt)
    mut arm_cnt = (do $scale_for $arm_unbuilt)
    mut darwin_cnt = (do $scale_for $darwin_unbuilt)

    if $x86_cnt == 0 and $arm_cnt == 0 and $darwin_cnt == 0 {
        $x86_cnt = 1
    }

    let total_unscaled = $x86_cnt + $arm_cnt + $darwin_cnt
    if $total_unscaled > $max_runners {
        let non_x86 = (if $arm_cnt > 0 { 1 } else { 0 }) + (if $darwin_cnt > 0 { 1 } else { 0 })
        $arm_cnt = (if $arm_cnt > 0 { 1 } else { 0 })
        $darwin_cnt = (if $darwin_cnt > 0 { 1 } else { 0 })
        $x86_cnt = [
            ($max_runners - $non_x86)
            1
        ] | math max
    }

    print $"Build analysis: ($systems | length) unbuilt \(x86: ($x86_unbuilt), arm: ($arm_unbuilt), darwin: ($darwin_unbuilt)\), allocating ($x86_cnt) x86_64, ($arm_cnt) aarch64, ($darwin_cnt) aarch64-darwin"
    {x86: $x86_cnt, arm: $arm_cnt, darwin: $darwin_cnt}
}

# Systems of the derivations `nix build` would build for these installables,
# or null if they could not be evaluated.
def unbuilt-systems [installables: list<string>]: nothing -> any {
    print $"Evaluating ($installables | str join ' ')..."
    let res = (^nix build --dry-run --no-link ...$installables | complete)
    if $res.exit_code != 0 {
        let tail = $res.stderr | lines | last 5 | str join "\n"
        print --stderr $"Warning: could not evaluate the build:\n($tail)"
        return null
    }
    let drvs = ($res.stderr
        | lines
        | each {|l| $l | str trim }
        | where {|l| ($l | str starts-with "/nix/store/") and ($l | str ends-with ".drv") })
    if ($drvs | is-empty) {
        return []
    }
    $drvs
    | chunks 200
    | each {|chunk|
        let shown = (^nix derivation show ...$chunk | complete)
        let parsed = if $shown.exit_code == 0 {
            try { $shown.stdout | from json } catch { {} }
        } else { {} }
        let table = if "derivations" in ($parsed | columns) { $parsed.derivations } else { $parsed }
        $table | values | get --optional system | compact
    }
    | flatten
}

def short-hostname []: nothing -> string {
    if $nu.os-info.name == "macos" {
        let local = (^scutil --get LocalHostName | complete)
        if $local.exit_code == 0 {
            return ($local.stdout | str trim)
        }
    }
    ^hostname | str trim | split row "." | first
}

# Split "ref#name" into its parts, defaulting the name.
def split-flake [ref: string, default_name: string]: nothing -> record {
    let parts = $ref | split row "#"
    let name = $parts.1? | default "" | str trim --char '"'
    {
        ref: $parts.0
        name: (if ($name | is-empty) { $default_name } else { $name })
    }
}

# Value of a flag in an argument list (`--flag value` or `--flag=value`).
def flag-value [args: list<string>, names: list<string>]: nothing -> any {
    mut found: any = null
    mut take_next = false
    for arg in $args {
        if $take_next {
            $found = $arg
            $take_next = false
        } else if $arg in $names {
            $take_next = true
        } else {
            for name in $names {
                if ($name | str starts-with "--") and ($arg | str starts-with $"($name)=") {
                    $found = ($arg | str substring (($name | str length) + 1)..)
                }
            }
        }
    }
    $found
}

# Positional arguments, skipping flags and the values of flags that take one.
def positionals [args: list<string>, value_flags: list<string>]: nothing -> list<string> {
    mut out = []
    mut skip_next = false
    for arg in $args {
        if $skip_next {
            $skip_next = false
        } else if $arg == "--" {
            break
        } else if $arg in $value_flags {
            $skip_next = true
        } else if not ($arg | str starts-with "-") {
            $out ++= [$arg]
        }
    }
    $out
}

# Name of a homeConfigurations entry: "user@host" if present, else "user".
def home-config-name [ref: string]: nothing -> string {
    let user = $env.USER? | default (^whoami | str trim)
    let qualified = $"($user)@(short-hostname)"
    let names = (
        ^nix eval --json $"($ref)#homeConfigurations" --apply builtins.attrNames
        | complete
    )
    let names = if $names.exit_code == 0 {
        try {
            $names.stdout | from json
        } catch {
            []
        }
    } else {
        []
    }
    if $qualified in $names { $qualified } else { $user }
}

# The flake outputs a system-switching command will build, if recognised.
def infer-installables [cmd: list<string>]: nothing -> list<string> {
    if ($cmd | is-empty) {
        return []
    }
    let prog = $cmd.0 | path basename
    let args = $cmd | skip 1
    let host = short-hostname

    if $prog in ["nixos-rebuild" "nixos-rebuild-ng"] {
        if ($args | any {|a| $a in ["build-vm" "build-vm-with-bootloader" "build-image" "list-generations" "repl" "edit"] }) {
            return []
        }
        let flake = (
            first-set [
                (flag-value $args ["--flake"])
                (
                    if ("/etc/nixos/flake.nix" | path exists) { "/etc/nixos" } else { null }
                )
            ]
        )
        if $flake == null {
            return []
        }
        let target = split-flake $flake $host
        return [
            $"($target.ref)#nixosConfigurations.\"($target.name)\".config.system.build.toplevel"
        ]
    }

    if $prog == "darwin-rebuild" {
        let flake = (
            first-set [
                (flag-value $args ["--flake"])
                (
                    if ("/etc/nix-darwin/flake.nix" | path exists) { "/etc/nix-darwin" } else { null }
                )
            ]
        )
        if $flake == null {
            return []
        }
        let target = split-flake $flake $host
        return [$"($target.ref)#darwinConfigurations.\"($target.name)\".system"]
    }

    if $prog == "home-manager" {
        let default_dir = (
            $env.XDG_CONFIG_HOME?
            | default ($env.HOME | path join ".config")
            | path join "home-manager"
        )
        let flake = (
            first-set [
                (flag-value $args ["--flake"])
                (
                    if ($default_dir | path join "flake.nix" | path exists) { $default_dir } else { null }
                )
            ]
        )
        if $flake == null {
            return []
        }
        let parts = $flake | split row "#"
        let name = if ($parts.1? | is-not-empty) { $parts.1 } else { home-config-name $parts.0 }
        return [$"($parts.0)#homeConfigurations.\"($name)\".activationPackage"]
    }

    if $prog == "nh" and ($args | length) >= 2 {
        let kind = $args.0
        let sub_args = $args | skip 2
        if not ($args.1 in ["switch" "boot" "test" "build"]) {
            return []
        }
        let value_flags = [
            "-H"
            "--hostname"
            "-c"
            "--configuration"
            "-s"
            "--specialisation"
            "-o"
            "--out-link"
            "--target-host"
            "--build-host"
            "-b"
            "--backup-extension"
            "-e"
            "--elevation-strategy"
            "--diff"
        ]
        let given = positionals $sub_args $value_flags | get 0?
        let env_flake = match $kind {
            "os" => (first-set [$env.NH_OS_FLAKE? $env.NH_FLAKE?])
            "home" => (first-set [$env.NH_HOME_FLAKE? $env.NH_FLAKE?])
            "darwin" => (first-set [$env.NH_DARWIN_FLAKE? $env.NH_FLAKE?])
            _ => null
        }
        let flake = first-set [$given $env_flake]
        if $flake == null {
            return []
        }
        match $kind {
            "os" => {
                let target = split-flake $flake (first-set [
                    (flag-value $sub_args ["-H" "--hostname"])
                    $host
                ])
                [
                    $"($target.ref)#nixosConfigurations.\"($target.name)\".config.system.build.toplevel"
                ]
            }
            "darwin" => {
                let target = split-flake $flake (first-set [
                    (flag-value $sub_args ["-H" "--hostname"])
                    $host
                ])
                [
                    $"($target.ref)#darwinConfigurations.\"($target.name)\".system"
                ]
            }
            "home" => {
                let parts = $flake | split row "#"
                let name = (first-set [
                    (flag-value $sub_args ["-c" "--configuration"])
                    ($parts.1? | default "")
                ])
                let name = if $name == null { home-config-name $parts.0 } else { $name }
                [$"($parts.0)#homeConfigurations.\"($name)\".activationPackage"]
            }
            _ => []
        }
    } else {
        []
    }
}

def make-nodes [session_id: string, counts: record]: nothing -> list<record> {
    [
        ...(
            0..<$counts.x86
            | each {|i| { id: $"x86-($i)", os: "ubuntu-latest", system: "x86_64-linux,i686-linux", cores: 4, host: $"nix-builder-($session_id)-x86-($i)" } }
        )
        ...(
            0..<$counts.arm
            | each {|i| { id: $"arm-($i)", os: "ubuntu-26.04-arm", system: "aarch64-linux", cores: 4, host: $"nix-builder-($session_id)-arm-($i)" } }
        )
        ...(
            0..<$counts.darwin
            | each {|i| { id: $"darwin-($i)", os: "macos-latest", system: "aarch64-darwin", cores: 3, host: $"nix-builder-($session_id)-darwin-($i)" } }
        )
    ]
}

# Tell builders the session is over; their watchdog then exits (after any linger).
def signal-done [nodes: list<any>] {
    print "\nShutting down remote builders..."
    $nodes | par-each {|node|
        ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 $"runner@($node.host)" "touch /tmp/nix-builder-done" | complete
    } | ignore
}

# Dispatch the builders and wait until all are reachable over Tailscale SSH.
# Returns {id, nodes, specs}; exits on failure after signalling any started builders.
def start-session [
    provider: string
    settings: record
    counts: record
    target_desc: string
    timeouts: record
]: nothing -> record {
    let counts = if ($counts.x86 + $counts.arm + $counts.darwin) <= 0 {
        {x86: 1, arm: 0, darwin: 0}
    } else { $counts }

    # see https://codeberg.org/wvhulle/nu-lint/issues/114
    # nu-lint-ignore: nu_parse_error
    let session_id = $"b(random chars --length 6 | str lowercase)"
    let nodes = make-nodes $session_id $counts
    let matrix_json = ({
        include: ($nodes | select id os)
    } | to json --raw)

    # Host keys learned while probing, pinned into the builder spec so the
    # nix-daemon (often root, with its own known_hosts) trusts the runners.
    let known_hosts_dir = (mktemp --directory --tmpdir nix-remote.XXXXXX)
    let fail = {||
        try { rm --recursive --force $known_hosts_dir }
        signal-done $nodes
        exit 1
    }

    if $provider == "gha" {
        let env_log = if $settings.environment != null { $"\n  Environment: ($settings.environment)" } else { "" }
        print $"\nDispatching GitHub Actions workflow on ($settings.repo)...($env_log)\n  Tailscale Tags: ($settings.tags)\n  Session: ($session_id)\n  Target: ($target_desc)\n  Total builders: ($nodes | length) \(x86: ($counts.x86), arm: ($counts.arm), darwin: ($counts.darwin)\)"

        mut gh_args = [
            workflow
            run
            nix-builder.yml
            --repo
            $settings.repo
            -f
            $"session_id=($session_id)"
            -f
            $"target=($target_desc)"
            -f
            $"matrix=($matrix_json)"
            -f
            $"tailscale_tags=($settings.tags)"
            -f
            $"timeout_startup=($timeouts.startup)"
            -f
            $"timeout_idle=($timeouts.idle)"
            -f
            $"timeout_linger=($timeouts.linger)"
        ]

        if $settings.environment != null {
            $gh_args ++= [-f $"environment=($settings.environment)"]
        }

        let dispatch_res = gh ...$gh_args | complete
        if $dispatch_res.exit_code != 0 {
            print --stderr $"Error dispatching workflow: ($dispatch_res.stderr)"
            do $fail
        }
    } else {
        print --stderr $"Error: Unsupported provider '($provider)'."
        do $fail
    }

    print "\nWaiting for builders to join Tailnet (Tailscale SSH)..."
    let start_time = (date now)
    mut ready_hosts = []

    while ($ready_hosts | length) < ($nodes | length) {
        let elapsed = ((date now) - $start_time) // 1sec
        if $timeouts.startup > 0 and $elapsed >= $timeouts.startup {
            print --stderr $"\nError: Timed out waiting for runners after ($timeouts.startup)s."
            do $fail
        }

        if $provider == "gha" {
            let failed = try {
                gh run list --repo $settings.repo --limit 5 --json databaseId,status,conclusion,displayTitle
                | from json
                | where status == "completed" and conclusion in [failure cancelled startup_failure timed_out] and ($it.displayTitle? | default "" | str contains $"[($session_id)]")
                | first
            }
            if $failed != null {
                print --stderr $"\nError: GitHub Actions workflow run failed with conclusion '($failed.conclusion)'.\nView logs: https://github.com/($settings.repo)/actions/runs/($failed.databaseId)"
                do $fail
            }
        }

        let newly_ready = ($nodes
            | where not ($it.host in $ready_hosts)
            | par-each {|node|
                let known_hosts = $known_hosts_dir | path join $node.host
                let probe = ssh -q -o StrictHostKeyChecking=accept-new -o $"UserKnownHostsFile=($known_hosts)" -o HashKnownHosts=no -o ConnectTimeout=2 -o BatchMode=yes $"runner@($node.host)" "true" | complete
                if ($probe.exit_code == 0) {
                    $node
                } else {
                    null
                }
            }
            | compact
        )

        for node in $newly_ready {
            $ready_hosts ++= [$node.host]
            print $"  Builder online: ($node.host) \(($node.system)\)"
        }

        if ($ready_hosts | length) < ($nodes | length) {
            sleep 5sec
        }
    }

    print $"\nAll ($nodes | length) builders online."

    let specs = ($nodes | each {|node|
        let host_key = host-key-b64 ($known_hosts_dir | path join $node.host)
        $"ssh-ng://runner@($node.host)?remote-program=/nix/var/nix/profiles/default/bin/nix-daemon ($node.system) - ($node.cores) 1 kvm,benchmark,big-parallel - ($host_key)"
    })
    try { rm --recursive --force $known_hosts_dir }

    {
        id: $session_id
        nodes: ($nodes | select host system)
        specs: $specs
    }
}

def sessions-dir [machines_file: path]: nothing -> string {
    $machines_file | path dirname | path join "sessions"
}

# Write a file atomically, group-writable so other members can update it.
def write-shared [file: path, content: string] {
    let tmp = $"($file).tmp.(random chars --length 6)"
    $content | save --force $tmp
    ^chmod 0664 $tmp
    mv --force $tmp $file
}

def read-sessions [machines_file: path]: nothing -> list<record> {
    let dir = sessions-dir $machines_file
    if not ($dir | path exists) {
        return []
    }
    ls $dir
    | where name =~ '\.json$'
    | each {|f| try { open $f.name } catch { null } }
    | compact
}

# Regenerate the machines file from the registered sessions.
def write-machines [machines_file: path] {
    let lines = read-sessions $machines_file | each {|s| $s.specs } | flatten
    let header = "# Managed by nix-remote. Active builder sessions; see `nix-remote status`."
    write-shared $machines_file ([$header ...$lines] | str join "\n" | $in + "\n")
}

def register-session [machines_file: path, session: record] {
    let dir = sessions-dir $machines_file
    mkdir $dir
    write-shared ($dir | path join $"($session.id).json") ($session | to json)
    write-machines $machines_file
}

def unregister-session [machines_file: path, id: string] {
    rm --force (sessions-dir $machines_file | path join $"($id).json")
    write-machines $machines_file
}

# Whether the machines file can be shared with the nix-daemon (writable location).
def machines-file-usable [machines_file: path]: nothing -> bool {
    let dir = $machines_file | path dirname
    if not ($dir | path exists) {
        try { mkdir $dir } catch { return false }
    }
    let probe = $dir | path join $".nix-remote-probe-(random chars --length 6)"
    try {
        "" | save $probe
        rm $probe
        true
    } catch { false }
}

def nix-config-with [specs: list<string>, local_jobs: int, substitutes: bool]: nothing -> string {
    let existing = $env.NIX_CONFIG? | default ""
    [
        $existing
        $"builders = ($specs | str join ';')"
        $"builders-use-substitutes = ($substitutes)"
        $"max-jobs = ($local_jobs)"
    ] | where ($it | is-not-empty) | str join "\n"
}

# Distribute Nix builds across on-demand cloud runners over Tailscale SSH.
#
# Subcommands: `exec` wraps any command (nh, nixos-rebuild, ...), `up`/`down`/`status`
# manage machine-wide sessions read by the nix-daemon.
def main [
  --provider: string = "gha" # Cloud provider backend
  --fast # Use nix-fast-build for pipelined eval + remote builds
  --built-in # Force standard nix CLI executor
  --max-runners: int = 4 # Maximum auto-scaled runners
  --runners: int # Force an exact total number of runners
  --x86: int # Force an exact x86_64-linux runner count
  --arm: int # Force an exact aarch64-linux runner count
  --darwin: int # Force an exact aarch64-darwin runner count
  --local-jobs: int = 0 # Local Nix jobs limit (0 offloads all builds to remote)
  --timeout-startup: int = 300 # Seconds to wait for initial runner connection
  --timeout-idle: int = 300 # Seconds of inactivity before runner disconnects
  --timeout-linger: int = 0 # Seconds to keep runner alive after build completion
  --repo: string # Target repository hosting the runner workflow (owner/repo)
  --environment: string # GitHub Actions environment name containing secrets
  --tailscale-tags: string # Tailscale ACL tags to apply to runner nodes
  --keep-alive # Keep runners alive after command finishes
  --no-builder-substitutes # Copy every input from this machine instead of letting builders use their substituters
  ...rest: string # Nix command and arguments (e.g. build .#default)
] {
    if $fast and $built_in {
        print --stderr "Error: --fast and --built-in are mutually exclusive."
        exit 1
    }

    if ($rest | is-empty) {
        print --stderr "Error: No Nix command specified."
        help main
        exit 1
    }

    let nix_args = if $rest.0 == "nix" {
        $rest | skip 1
    } else {
        $rest
    }

    if ($nix_args | is-empty) {
        print --stderr "Error: No Nix subcommand specified after 'nix'."
        exit 1
    }

    if $provider == "gha" {
        check-cmd { gh auth status } "Error: GitHub CLI ('gh') is not authenticated or not installed.\nPlease run 'gh auth login' or export GITHUB_TOKEN."
    }
    check-cmd { tailscale status } "Error: Tailscale is not running, not authenticated, or not installed.\nPlease run 'tailscale up' or 'tailscale login'."

    let settings = resolve-settings $repo $environment $tailscale_tags null

    let explicit = explicit-counts $runners $x86 $arm $darwin
    let counts = if $explicit != null {
        print $"Using explicit runner configuration: ($explicit.x86) x86, ($explicit.arm) ARM, ($explicit.darwin) Darwin"
        $explicit
    } else {
        print "Evaluating build requirements..."

        let is_flake_check = ($nix_args.0 == "flake" and ($nix_args.1? == "check"))

        mut unbuilt_systems = []
        if $is_flake_check {
            let eval_res = (
                nix-eval-jobs --check-cache-status --force-recurse --flake . --select "flake: (flake.outputs.checks or {})"
                | complete
            )
            if $eval_res.exit_code == 0 and ($eval_res.stdout | str trim | is-not-empty) {
                $unbuilt_systems = ($eval_res.stdout
                    | lines
                    | where ($it | str starts-with "{")
                    | each {|l| try { $l | from json } catch { null } }
                    | where $it != null and ($it.fatal? != true) and ((not ($it.isCached? | default false)))
                    | get --optional system
                    | compact
                )
            }
        } else {
            let dry_args = if $nix_args.0 == "build" {
                [...$nix_args, "--dry-run", "--json"]
            } else {
                [
                    "build"
                    ...($nix_args | skip 1)
                    "--dry-run"
                    "--json"
                ]
            }
            let dry_res = (^nix ...$dry_args | complete)
            if $dry_res.exit_code != 0 {
                print --stderr $dry_res.stderr
                exit $dry_res.exit_code
            }
            let drvs = try {
                $dry_res.stdout | from json | get --optional drvPath | compact
            } catch { [] }

            if ($drvs | is-not-empty) {
                let drv_info = (
                    ^nix derivation show ...$drvs
                    | complete
                    | get stdout
                    | from json
                )
                $unbuilt_systems = ($drv_info.derivations | values | get system)
            }
        }

        if ($unbuilt_systems | is-empty) {
            print "All derivations are cached. No remote builders needed.\nExecuting locally..."
            ^nix ...$nix_args
            return
        }

        scale-counts $unbuilt_systems $max_runners
    }

    let target_desc = ['nix' ...$nix_args] | str join ' '
    let session = (start-session $provider $settings $counts $target_desc {
        startup: $timeout_startup
        idle: $timeout_idle
        linger: $timeout_linger
    })
    let nodes = $session.nodes

    let do_cleanup = {|keep: bool|
        if not $keep {
            signal-done $nodes
        } else {
            print "\nKeep-alive enabled. Builders will stay running until their timeout."
        }
    }

    let builders_arg = $session.specs | str join ";"
    let substitutes = if $no_builder_substitutes { "false" } else { "true" }

    let use_fast = if $fast {
        true
    } else if $built_in {
        false
    } else {
        # Sane automatic default:
        # Use fast (nix-fast-build) for flake check or batch attribute builds (.#checks, .#packages)
        let is_check = ($nix_args.0 == "flake" and ($nix_args.1? == "check"))
        let is_batch = ($nix_args | any {|a|
            ($a | str starts-with ".#checks") or ($a | str starts-with ".#packages") or ($a | str starts-with ".#legacyPackages")
        })
        let is_unsupported_subcmd = ($nix_args.0 in ["run", "shell", "develop"])

        ($is_check or $is_batch) and (not $is_unsupported_subcmd)
    }

    if $use_fast {
        let flake_target = if ($nix_args.0 == "flake") and ($nix_args.1? == "check") {
            ".#checks"
        } else if ($nix_args.0 == "build") and (($nix_args | length) > 1) {
            $nix_args.1
        } else {
            ".#checks"
        }

        print $"\nRunning with nix-fast-build: flake target '($flake_target)'\n"

        try {
            nix-fast-build --flake $flake_target --option builders $builders_arg --option builders-use-substitutes $substitutes --option max-jobs ($local_jobs | into string) --no-nom
            do $do_cleanup $keep_alive
        } catch {|err|
            do $do_cleanup $keep_alive
            error make --unspanned {msg: $"nix-fast-build failed: ($err.msg)"}
        }
    } else {
        print $"\nRunning: nix ($nix_args | str join ' ')\n"

        try {
            ^nix ...$nix_args --builders $builders_arg --option builders-use-substitutes $substitutes --max-jobs $local_jobs
            do $do_cleanup $keep_alive
        } catch {|err|
            do $do_cleanup $keep_alive
            error make --unspanned {msg: $"Nix build failed: ($err.msg)"}
        }
    }
}

# Run any command (nh, nixos-rebuild, darwin-rebuild, home-manager, ...) with remote builders.
#
# The builders are passed through NIX_CONFIG and, when the machines file is writable
# (see the NixOS/nix-darwin module), also registered with the nix-daemon so builds
# started by root or another user use them too.
def "main exec" [
  --provider: string = "gha" # Cloud provider backend
  --for: string # Installable to size builders from (inferred for nh/nixos-rebuild/darwin-rebuild/home-manager)
  --max-runners: int = 4 # Maximum auto-scaled runners
  --runners: int # Force an exact total number of runners
  --x86: int # Force an exact x86_64-linux runner count
  --arm: int # Force an exact aarch64-linux runner count
  --darwin: int # Force an exact aarch64-darwin runner count
  --local-jobs: int = 0 # Local Nix jobs limit (0 offloads all builds to remote)
  --timeout-startup: int = 300 # Seconds to wait for initial runner connection
  --timeout-idle: int = 300 # Seconds of inactivity before runner disconnects
  --timeout-linger: int = 0 # Seconds to keep runner alive after build completion
  --repo: string # Target repository hosting the runner workflow (owner/repo)
  --environment: string # GitHub Actions environment name containing secrets
  --tailscale-tags: string # Tailscale ACL tags to apply to runner nodes
  --machines-file: path # Machines file shared with the nix-daemon
  --keep-alive # Keep runners alive after command finishes
  --no-builder-substitutes # Copy every input from this machine instead of letting builders use their substituters
  ...cmd: string # Command to run (e.g. nh os switch .)
] {
    if ($cmd | is-empty) {
        print --stderr "Error: No command specified, e.g. `nix-remote exec -- nh os switch .`."
        exit 1
    }

    let run = {|nix_config: any|
        let code = if $nix_config == null {
            try {
                ^$cmd.0 ...($cmd | skip 1)
                0
            } catch {|e|
                $e.exit_code? | default 1
            }
        } else {
            with-env {NIX_CONFIG: $nix_config} {
                try { ^$cmd.0 ...($cmd | skip 1); 0 } catch {|e| $e.exit_code? | default 1 }
            }
        }
        $code
    }

    let explicit = explicit-counts $runners $x86 $arm $darwin
    let installables = if $for != null { [$for] } else if $explicit == null { infer-installables $cmd } else { [] }

    let counts = if $explicit != null {
        $explicit
    } else if ($installables | is-not-empty) {
        let systems = unbuilt-systems $installables
        if $systems == null {
            default-counts
        } else if ($systems | is-empty) {
            print "All derivations are cached. No remote builders needed."
            exit (do $run null)
        } else {
            scale-counts $systems $max_runners
        }
    } else {
        print "Could not tell what this command builds; starting one builder for this machine's system (use --for or --x86/--arm/--darwin)."
        default-counts
    }

    if $provider == "gha" {
        check-cmd { gh auth status } "Error: GitHub CLI ('gh') is not authenticated or not installed.\nPlease run 'gh auth login' or export GITHUB_TOKEN."
    }
    check-cmd { tailscale status } "Error: Tailscale is not running, not authenticated, or not installed.\nPlease run 'tailscale up' or 'tailscale login'."

    let settings = resolve-settings $repo $environment $tailscale_tags $machines_file
    let session = (start-session $provider $settings $counts ($cmd | str join ' ') {
        startup: $timeout_startup
        idle: $timeout_idle
        linger: $timeout_linger
    })

    let shared = machines-file-usable $settings.machines_file
    if $shared {
        register-session $settings.machines_file (
            $session
            | merge {repo: $settings.repo, created: (date now | format date "%+")}
        )
    }

    print $"\nRunning: ($cmd | str join ' ')\n"
    let code = do $run (nix-config-with $session.specs $local_jobs (not $no_builder_substitutes))

    if $shared {
        unregister-session $settings.machines_file $session.id
    }
    if $keep_alive {
        print "\nKeep-alive enabled. Builders will stay running until their timeout."
    } else {
        signal-done $session.nodes
    }
    exit $code
}

# Start builders and register them with the nix-daemon until `nix-remote down`.
#
# Every build on this machine (nh, nixos-rebuild, nix build, root or any user) can then
# use them, provided the daemon's `builders` setting includes `@<machines file>`.
def "main up" [
  --provider: string = "gha" # Cloud provider backend
  --for: string # Installable to size builders from
  --max-runners: int = 4 # Maximum auto-scaled runners
  --runners: int # Force an exact total number of runners
  --x86: int # Force an exact x86_64-linux runner count
  --arm: int # Force an exact aarch64-linux runner count
  --darwin: int # Force an exact aarch64-darwin runner count
  --timeout-startup: int = 300 # Seconds to wait for initial runner connection
  --timeout-idle: int = 900 # Seconds without builds before runners shut down
  --repo: string # Target repository hosting the runner workflow (owner/repo)
  --environment: string # GitHub Actions environment name containing secrets
  --tailscale-tags: string # Tailscale ACL tags to apply to runner nodes
  --machines-file: path # Machines file shared with the nix-daemon
] {
    let explicit = explicit-counts $runners $x86 $arm $darwin
    let counts = if $explicit != null {
        $explicit
    } else if $for != null {
        let systems = unbuilt-systems [$for]
        if $systems == null {
            default-counts
        } else if ($systems | is-empty) {
            print "All derivations are cached. No remote builders needed."
            return
        } else {
            scale-counts $systems $max_runners
        }
    } else {
        default-counts
    }

    if $provider == "gha" {
        check-cmd { gh auth status } "Error: GitHub CLI ('gh') is not authenticated or not installed.\nPlease run 'gh auth login' or export GITHUB_TOKEN."
    }
    check-cmd { tailscale status } "Error: Tailscale is not running, not authenticated, or not installed.\nPlease run 'tailscale up' or 'tailscale login'."

    let settings = resolve-settings $repo $environment $tailscale_tags $machines_file
    if not (machines-file-usable $settings.machines_file) {
        print --stderr $"Error: cannot write ($settings.machines_file). Enable the nix-remote NixOS/nix-darwin module or set --machines-file."
        exit 1
    }

    let session = (start-session $provider $settings $counts "nix-remote up" {
        startup: $timeout_startup
        idle: $timeout_idle
        linger: 0
    })
    register-session $settings.machines_file (
        $session
        | merge {repo: $settings.repo, created: (date now | format date "%+")}
    )

    print $"\nSession ($session.id) registered in ($settings.machines_file)."
    print $"Builds on this machine now use these builders. They shut down after ($timeout_idle)s without builds, or with `nix-remote down`."
}

# Stop builder sessions and remove them from the machines file.
def "main down" [
  --machines-file: path # Machines file shared with the nix-daemon
  session?: string # Session to stop (default: all)
] {
    let settings = resolve-settings "-" null null $machines_file
    let sessions = read-sessions $settings.machines_file | where {|s| $session == null or $s.id == $session }
    if ($sessions | is-empty) {
        print "No active sessions."
        return
    }
    for s in $sessions {
        print $"Stopping session ($s.id) \(($s.nodes | length) builders\)"
        signal-done $s.nodes
        unregister-session $settings.machines_file $s.id
    }
}

# Show builder sessions, dropping builders that are no longer reachable.
def "main status" [
  --machines-file: path # Machines file shared with the nix-daemon
] {
    let settings = resolve-settings "-" null null $machines_file
    let sessions = read-sessions $settings.machines_file
    if ($sessions | is-empty) {
        print $"No active sessions in ($settings.machines_file)."
        return
    }
    let dir = sessions-dir $settings.machines_file
    let report = ($sessions | each {|s|
        let alive = ($s.nodes | enumerate | par-each {|n|
            let probe = ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes $"runner@($n.item.host)" "true" | complete
            if $probe.exit_code == 0 { $n.index } else { null }
        } | compact | sort)
        let file = $dir | path join $"($s.id).json"
        if ($alive | is-empty) {
            rm --force $file
        } else if ($alive | length) < ($s.nodes | length) {
            let kept = $s | merge {
                nodes: ($alive | each {|i| $s.nodes | get $i })
                specs: ($alive | each {|i| $s.specs | get $i })
            }
            write-shared $file ($kept | to json)
        }
        {session: $s.id, repo: ($s.repo? | default ""), builders: ($s.nodes | length), online: ($alive | length), created: ($s.created? | default "")}
    })
    write-machines $settings.machines_file
    print ($report | table)
}
