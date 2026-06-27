<div align="center">

# 🎬 mediaoptimizer

### Shrink your whole media library to HEVC — on one box, or across a whole fleet of Macs 🚀

![shell](https://img.shields.io/badge/bash-5%2B-1f425f?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-macOS%20%2B%20Linux-555?logo=apple&logoColor=white)
![encoders](https://img.shields.io/badge/encoders-QSV%20%7C%20VideoToolbox-orange)
![deps](https://img.shields.io/badge/deps-ffmpeg%20%2B%20ssh-brightgreen)
![status](https://img.shields.io/badge/status-running%20in%20production-success)
![license](https://img.shields.io/badge/license-Apache--2.0-blue)

*Re-encode H.264 → HEVC at ~**70% smaller**, **verify before replacing**, never touch what's already lean — and fan the work out across every idle Apple Silicon media engine you own.*

</div>

> [!NOTE]
> **Honest status:** this runs in production on the author's fleet (TrueNAS + 4 Apple Silicon Macs), clearing a ~3,000-episode library. It's a set of focused, battle-tested **bash scripts**, not a packaged app — you wire it to *your* NAS + nodes via one config file. No secrets ship in the repo; copy `farm.conf.example` → `farm.conf` (gitignored) and go.

---

## 🗺️ Table of Contents

| | | |
|---|---|---|
| 🤔 [Why](#why) | 🧠 [Core Concepts](#core-concepts) | 🏗️ [Architecture](#architecture) |
| 🔄 [How It Works](#how-it-works) | 🛡️ [Safety Model](#safety-model) | 🎛️ [Two Ways to Run](#two-ways-to-run) |
| ⚡ [Quick Start](#quick-start) | 🧰 [CLI & Config](#cli-config) | 📊 [Benchmarks](#benchmarks) |
| 🧪 [Cross-Platform](#cross-platform) | 🗺️ [Roadmap](#roadmap) | 🤝 [Contributing](#contributing) |

---

## 🤔 Why

You've got terabytes of H.264 and a pile of Apple Silicon with **dedicated media engines sitting idle** (they don't even compete with your GPU/ML work). Meanwhile most "transcode everything" tools either hammer one box, re-encode stuff that's already small, or replace originals with zero verification. 😬

| | 🎬 mediaoptimizer | 🐌 naive `for f in *; ffmpeg` | 🖥️ single-box transcoder |
|---|:---:|:---:|:---:|
| Skips already-HEVC / HDR / low-bitrate | ✅ | ❌ | ⚠️ sometimes |
| **Verifies** output before replacing | ✅ codec + duration | ❌ | ⚠️ rarely |
| Recoverable rolling trash (FIFO) | ✅ | ❌ | ⚠️ |
| Resumable (shared state, dedup) | ✅ | ❌ | ⚠️ |
| Fan out across many machines | ✅ N nodes | ❌ | ❌ |
| Uses idle Apple Silicon media engines | ✅ VideoToolbox | ❌ | ❌ |
| Survives reboot / crash | ✅ launchd `KeepAlive` | ❌ | ⚠️ |

---

## 🧠 Core Concepts

```mermaid
mindmap
  root((media<br/>optimizer))
    🎯 Decide
      probe codec/res/bitrate
      skip already-hevc
      skip HDR / low-res / low-bitrate
    🔧 Encode
      QSV ICQ  ·  Intel iGPU
      VideoToolbox  ·  Apple Silicon
      only-downscale to 1080p
    🛡️ Safety
      encode then verify
      atomic in-place replace
      rolling size-capped trash
    🌐 Fan out
      disjoint slices per node
      shared state dedup
      ssh pull / push
      launchd daemons
```

---

## 🏗️ Architecture

Two file homes, one shared brain. The **NAS** holds the library + the shared state file + a tiny persistent `ffmpeg` container for fast probing. Each **node** owns a disjoint slice and does the heavy lifting on its own media engine.

```mermaid
flowchart LR
    CTL["🧑‍💻 control box<br/>farm-deploy.sh + farm.conf"]
    subgraph NAS["🗄️ NAS (file server)"]
      LIB["📚 media library"]
      STATE["📒 shared state.tsv"]
      PROBE["🐳 hevc-probe<br/>(ffprobe, docker exec)"]
    end
    subgraph FLEET["🍎 Apple Silicon nodes"]
      N1["node 1 · VideoToolbox<br/>conc=3"]
      N2["node 2 · VideoToolbox<br/>conc=3"]
      N3["node 3 · VideoToolbox<br/>conc=2"]
    end
    CTL -- "scp worker + install launchd" --> FLEET
    N1 & N2 & N3 -- "probe (no pull)" --> PROBE
    N1 & N2 & N3 -- "pull h264 / push hevc (ssh)" --> LIB
    N1 & N2 & N3 -- "append done rows" --> STATE
    STATE -. "dedup: skip what's done" .-> FLEET
```

> 💡 **Single-box mode** drops the fleet entirely: one Docker container on the NAS encodes in place with the Intel iGPU (QSV). Same brain, no ssh.

---

## 🔄 How It Works

Each file flows through the same pipeline — but the farm **probes remotely first** so it only ever pulls files it's actually going to convert (no wasting bandwidth pulling a 2 GB file just to learn it's already HEVC).

```mermaid
sequenceDiagram
    autonumber
    participant W as 🍎 node worker
    participant N as 🗄️ NAS
    W->>N: remote_probe (docker exec ffprobe) — no pull
    N-->>W: codec / res / bitrate / duration
    alt already-hevc · HDR · low-res · low-bitrate
        W->>N: record skip (no transfer) ✅
    else convert
        W->>N: pull source over ssh ⬇️
        W->>W: VideoToolbox encode → verify (codec+duration) 🔍
        alt verified & ≥ MIN_GAIN%
            W->>N: push HEVC ⬆️
            W->>N: atomic replace (orig → rolling trash) 🔁
            W->>N: append "done" to shared state 📒
        else failed / no gain
            W->>N: keep original, record reason 🛟
        end
    end
```

---

## 🛡️ Safety Model

Originals are precious. Nothing gets replaced unless the new file is **provably good**.

| Guard | What it does |
|---|---|
| 🔍 **Verify** | Output must be HEVC **and** within 1% of source duration, or the replace is aborted |
| 📉 **Min-gain** | If the HEVC isn't at least `MIN_GAIN_PCT` smaller, the original is kept |
| 🗑️ **Rolling trash** | Replaced originals go to a size-capped (`TRASH_CAP_GB`) trash in the **same dataset** → the swap is an instant atomic rename, and recent originals stay recoverable (FIFO by insertion time) |
| 🧊 **Atomic** | `mv` within one dataset — never a half-written file at the real path |
| 🔒 **Single instance** | `flock` (Linux) / atomic `mkdir`+PID lock (macOS) per node |
| 🧮 **Free-space floor** | Single-box mode pauses if the pool drops below `MIN_FREE_GB` |

---

## 🎛️ Two Ways to Run

<table>
<tr><th>🖥️ Single box (QSV)</th><th>🌐 Distributed (VideoToolbox)</th></tr>
<tr><td>

`hevc-convert.sh` in a Docker `ffmpeg` container, encoding **in place** with an Intel iGPU. Gentle: niced, sleeps between files, pauses while Plex transcodes.

Managed by **`hevcctl.sh`**.

</td><td>

`farm-worker.sh` on each Apple Silicon Mac — pulls over ssh, encodes with **VideoToolbox**, pushes back, replaces on the NAS. N nodes × concurrency.

Deployed by **`farm-deploy.sh`** + **`farm.conf`**.

</td></tr>
</table>

> 🧬 Both share the **same `hevc-convert.sh` core** (cross-platform: `ENCODER=qsv|videotoolbox`, BSD/GNU shims, portable lock). The farm worker is a thin ssh transport around that same decide/encode/verify logic.

---

## ⚡ Quick Start

### 🌐 The farm (Apple Silicon nodes + a NAS)

**Prereqs:** each node has `bash 5+` & `ffmpeg` (with `hevc_videotoolbox`) via Homebrew, passwordless `ssh` to the NAS, and passwordless `sudo` for the probe container. The NAS runs a persistent probe container (see below).

```bash
# 0. on the NAS — start the persistent probe container (one time)
docker run -d --name hevc-probe --restart unless-stopped \
  -v /srv/media:/media --entrypoint sleep \
  lscr.io/linuxserver/ffmpeg:latest infinity

# 1. configure
git clone <your-fork> mediaoptimizer && cd mediaoptimizer/scripts
cp farm.conf.example farm.conf
$EDITOR farm.conf          # nodes, slices, NAS host, paths

# 2. deploy auto-restarting daemons to every node
./farm-deploy.sh           # all nodes
./farm-deploy.sh status    # pulse check
```

### 🖥️ Single box (Intel QSV, in Docker)

```bash
MEDIA_DIR=/srv/media WORKDIR=/srv/hevc ./hevcctl.sh start
./hevcctl.sh status
```

---

## 🧰 CLI & Config

### `farm-deploy.sh`

| Command | Does |
|---|---|
| `./farm-deploy.sh` | Deploy worker + launchd daemon to **all** nodes |
| `./farm-deploy.sh <host>` | Deploy to one node |
| `./farm-deploy.sh status` | Daemon state + recent log per node |
| `./farm-deploy.sh stop` | Bootout the daemon on all nodes |

### `hevcctl.sh`

| Command | Does |
|---|---|
| `start` / `stop` / `restart` | Manage the single-box QSV container |
| `status` | Progress tally + pool free space |
| `logs [N]` · `stats` | Tail the log · live container stats |

### `farm.conf` (sourced; the only place your real values live — gitignored)

| Key | Meaning |
|---|---|
| `HOSTS` | Array of node ssh hosts |
| `SLICE[host]` | **Disjoint** newline-separated library subdirs per node |
| `CONC[host]` | Concurrent encodes per node (Ultra ≈ 3, Max/laptop ≈ 2) |
| `NAS` · `REMOTE_ROOT` · `STATE_REMOTE` | File server host, library root, shared state path |
| `PROBE_CTR` · `MEDIA_HOST` · `MEDIA_CANON` | Probe container + host→container path remap |
| `NODE_USER` · `NODE_DIR` · `NODE_BASH` · `LABEL` | Per-node daemon identity & install paths |

<details>
<summary>🎚️ Tuning knobs (env, both modes)</summary>

| Var | Default | Meaning |
|---|---|---|
| `VT_QUALITY` | `60` | VideoToolbox `-q:v` (1–100) |
| `QUALITY` | `22` | QSV ICQ `global_quality` |
| `MAX_W`×`MAX_H` | `1920`×`1080` | Only-downscale ceiling |
| `MIN_SRC_KBPS` | `3000` | Skip sources already leaner |
| `MIN_GAIN_PCT` | `8` | Output must be this % smaller |
| `TRASH_CAP_GB` | `80` | Rolling trash cap per dataset |
| `CONCURRENCY` | `1` | Parallel encodes per worker |
| `DRY_RUN` · `LIMIT` · `ONESHOT` | `0` | Preview · cap files · one pass (great for testing) |

</details>

---

## 📊 Benchmarks

> Measured on the author's fleet: 2× M3 Ultra, 1× M1 Ultra, 1× M3 Max, feeding from a TrueNAS box. **Your mileage varies with NAS bandwidth & node count.**

| Metric | Result |
|---|---|
| 📉 Size reduction | **~70%** average (H.264 → HEVC, VMAF stays high) |
| 🍎 VideoToolbox speed | ~**36× realtime** on a 1080p segment (single stream) |
| 🌐 Fleet throughput | **~60–100 converts/hour** at 11 concurrent across 4 nodes |
| ⏱️ ~1,600-file backlog | days on one NAS iGPU → **under a day** on the farm |

> ⚖️ **Reality check:** 3× concurrency ≈ 1.5–2× throughput, not 3×. The ceiling is the *shared media engine per machine + NAS pull bandwidth*, not idle compute — so past ~3-per you just add contention.

---

## 🧪 Cross-Platform

| | 🖥️ Linux / Intel | 🍎 macOS / Apple Silicon |
|---|:---:|:---:|
| Encoder | `hevc_qsv` (ICQ) | `hevc_videotoolbox` (`-q:v`) |
| Lock | `flock` | atomic `mkdir` + PID |
| `stat` / `df` | GNU | BSD shims |
| Role | single-box, in-place | farm node, ssh pull/push |
| Deploy | Docker container | launchd daemon |

---

## 🗺️ Roadmap

```mermaid
flowchart LR
    A["✅ QSV single-box"] --> B["✅ VideoToolbox farm"]
    B --> C["✅ concurrency + config"]
    C --> D["🔨 Plex-aware pause"]
    D --> E["⬜ auto-balance slices"]
    E --> F["⬜ web dashboard"]
```

| Status | Item |
|:---:|---|
| ✅ | Single-box QSV converter (Docker, in-place, verified) |
| ✅ | Distributed VideoToolbox farm (ssh pull/push, atomic replace) |
| ✅ | Remote-probe optimization (no pull-to-skip) |
| ✅ | Per-node concurrency + externalized `farm.conf` |
| ✅ | launchd auto-restart daemons (survives reboot/crash) |
| 🔨 | Plex-transcode-aware pause for farm workers |
| ⬜ | Auto-balance slices by measured node throughput |
| ⬜ | Web dashboard / live progress UI |
| ⬜ | AV1 (when Apple Silicon ships hardware AV1 encode) |
| ⬜ | Optional NFS/SMB transport where the OS cooperates |

---

## 🤝 Contributing

PRs welcome! Keep it **bash-portable** (works under the Linux/macOS shims), and never let a doc lie about the code. Before any change to behavior, run a `DRY_RUN=1 LIMIT=1` pass against a test slice.

> 📜 **License:** [Apache 2.0](LICENSE) — permissive, patent-grant included. Use it, fork it, ship it.

---

<div align="center">

### 🍿 Point it at your library, walk away, come back to half the disk usage.

*Built for hoarders with too many Macs and not enough SSD.* 💾✨

</div>
