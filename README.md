<div align="center">

<img width="100%" alt="header" src="https://capsule-render.vercel.app/api?type=waving&height=210&text=Sible%20Network%20Bot&fontAlign=50&fontAlignY=36&fontSize=56&desc=Mining%20%7C%20Ad%20Boost%20%7C%20Reward%20Tasks&descAlign=50&descAlignY=58"/>

<img alt="typing" src="https://readme-typing-svg.demolab.com?font=Inter&size=18&duration=3000&pause=650&center=true&vCenter=true&width=900&lines=Mining+Session+%2B+Ad+Boost+%2B+Claim;One+Time+Tasks+%7C+Daily+Tasks;Multi-Account+%7C+Sequential+Processing;Proxy+Support+%7C+One+Proxy+Per+Account"/>

<p>
  <img alt="elixir" src="https://img.shields.io/badge/Elixir-1.14%2B-4B275F?logo=elixir&logoColor=white"/>
  <img alt="platform" src="https://img.shields.io/badge/Platform-Sible%20Network%20Mining-111111"/>
  <img alt="multi-account" src="https://img.shields.io/badge/Multi--Account-Supported-111111"/>
  <img alt="proxy" src="https://img.shields.io/badge/Proxy-Supported-111111"/>
  <img alt="author" src="https://img.shields.io/badge/by-Yuurisandesu-111111"/>
</p>

<p>
  <b>Sible Network Bot</b> is a full automation bot for the Sible Network web mining.<br/>
  It refreshes the account session, runs the mining cycle, watches the rewarded videos, claims the settled mining reward and completes every reward task the account is eligible for, all running automatically across multiple accounts with proxy support and a live countdown between cycles.<br/>
  Built and distributed by <b>Yuurisandesu</b>.
</p>

</div>

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Bot](#running-the-bot)
- [Features](#features)
- [File Structure](#file-structure)
- [Disclaimer](#disclaimer)

---

## Requirements

- Elixir `1.14+` with Erlang/OTP `25+`
- Git

---

## Installation

### Install Elixir

Elixir runs on the Erlang virtual machine, so **Erlang/OTP is required** Elixir cannot run without
it. Every package manager below installs Erlang/OTP for you as a dependency. The only path that needs
a separate Erlang step is the Windows manual installer (see below).

**Windows:**

*Option A package manager (recommended, installs Erlang automatically):*

```cmd
winget install Elixir.Elixir
```

*Option B manual installer (two installers, in this order):*

1. Download and run the **Erlang/OTP installer** from https://www.erlang.org/downloads
2. Run `erl -s halt` to check which OTP version you got
3. Download the **Elixir installer built for that exact OTP** from https://elixir-lang.org/install.html (`elixir-otp-<N>.exe`) and run it

Then open Command Prompt and verify:

```cmd
elixir --version
```

The output prints both versions, for example `Elixir 1.14.0 (compiled with Erlang/OTP 25)`.

**Linux (Ubuntu / Debian):**

```bash
sudo apt-get update
sudo apt-get install -y elixir
elixir --version
```

**macOS:**

```bash
brew install elixir
elixir --version
```

> If you do not have Homebrew, install it first from https://brew.sh

**Termux (Android):**

```bash
pkg update && pkg upgrade -y
pkg install elixir -y
elixir --version
```

> If the `elixir` package is not available in your Termux repository, install an Ubuntu environment first with `pkg install proot-distro`, then `proot-distro install ubuntu`, then `proot-distro login ubuntu` and run the Linux command above inside it.

---

### Clone and Install

**Clone the repository:**

```bash
git clone https://github.com/Yuurisan-N1/Sible-Mining.git
cd Sible-Mining
```

**Install dependencies:**

This bot uses only the Elixir standard library, so there is nothing to install. Erlang/OTP was already installed by the step above.

---

## Configuration

### 1. Accounts (data.txt)

**refresh token** of the account, one per line:

```
709e2450fe275ec6e3d1...
8bd854eefff4aa2a319c...
```

### 2. Proxy (proxy.txt)

Fill `proxy.txt` with proxies, one per line (optional, leave empty to run without proxy):

```
host:port
host:port:user:pass
http://user:pass@host:port
```

Proxies are assigned to accounts by index in round-robin order.

### 3. Bot Settings (config.json)

`sleep_seconds` controls how many seconds the bot waits between cycles. If `config.json` is missing, it is created automatically with a default of `3600` seconds.

---

## Running the Bot

**Linux / macOS:**

```bash
elixir --erl "+Bd" bot.exs
```

**Windows:**

```cmd
elixir --erl "+Bc" bot.exs
```

Or just double click `run_pc.bat`, which runs the Windows command above.

---

## Features

### Account Session
Every account opens a session with its refresh token and the bot logs that the access token is now valid. The rotated refresh token is written back into `data.txt` so the next cycle uses the current one. An account that is banned, locked or whose token was revoked is reported and skipped instead of being processed.

### Mining Session
The mining status is read first. When the account has no running session and the server allows a new one, the session is started and the hourly rate the server returned is logged. A slot that was already activated today is reported as such instead of being counted as a failure.

### Ad Boost
Every rewarded video the account is still allowed to watch for the running session is watched in turn, paced so the server interval is respected, and the new hourly rate is logged after each one. A session with no ad left is reported honestly.

### Mining Claim
The mining reward is claimed whenever the server marks it as claimable. The claim is asynchronous, so the bot polls the claim status until the server settles it, and the settled amount is logged. A reward that is still settling is left for the next cycle instead of being forced.

### Reward Tasks
Every one time and daily reward task the account is eligible for is completed in turn: the task is opened, the required waiting time is respected with a live countdown, the account link is submitted for the social tasks and the reward is claimed. A task that is locked, not eligible yet or refused by the server is reported with the reason instead of being counted as a reward. The whole block is reported as a single line per account: the number of rewards that were claimed, the number of tasks that could not be completed, or that every available account task was already completed.

### Multi Account
All accounts in `data.txt` are processed sequentially within every cycle. Each account is logged with its index, its name and its balance. The cycle number is tracked and logged at the start of each round.

### Proxy Support
Proxies are loaded from `proxy.txt` and assigned to accounts by position in round-robin order. Proxy credentials are masked in log output. Running without proxies is fully supported.

### Auto Countdown
Every wait inside the cycle displays a live `HH:MM:SS` countdown in place, and after all accounts complete a cycle the bot shows a countdown until the next cycle starts.

---

## File Structure

```text
Sible-Mining/
├── bot.exs         # Main bot, full mining cycle automation
├── config.json     # Sleep duration between cycles
├── data.txt        # Account refresh tokens, one per line
├── proxy.txt       # Proxy list, one per line (optional)
├── run_pc.bat      # Launcher for Windows
├── LICENSE         # License file
└── utils/
    ├── banner.ex   # Banner display on startup
    └── json.ex     # JSON encoder and decoder
```

---

## Disclaimer

This tool is built for educational and technical exploration purposes. Use it wisely and at your own responsibility.

---

<div align="center">
<img width="100%" alt="footer" src="https://capsule-render.vercel.app/api?type=waving&height=120&section=footer"/>
</div>
