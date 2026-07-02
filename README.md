# pwsh-anime-attendance

> English | [繁體中文](README_ZH.md)

An auto attendance tool written in PowerShell, for online platforms like HoYoLAB, Skport, and Skland.

## Features

- **Multi-platform Support**:
    - **HoYoLAB**: Supports attendance for *Genshin Impact*, *Honkai: Star Rail*, *Zenless Zone Zero*, etc.
    - **Skport**: Supports attendance for *Arknights: Endfield*.
    - **Skland**: Supports attendance for *Arknights* and *Arknights: Endfield*.
- **Discord Notifications**:
    - **Message Reuse**: Intelligently updates the same Discord message to avoid notification clutter.
    - **Minimal Mode**: Option to display detailed reward info or a concise one-line summary.
    - **Error Tagging**: Automatically tags specific users or roles when cookies expire or manual CAPTCHA is required.
- **Highly Customizable**:
    - Supports multi-account and multi-bot configurations.
    - Custom User-Agent and language settings for different platforms.
- **Auto Re-sign**: Automates tasks and re-signing for HoYoLAB.

## Quick Start

### 1. Environment Requirements
Ensure your system has **PowerShell Core (7+)** or Windows PowerShell 5.1 (usually built-in) installed.

### 2. Download the files
Clone or download this repository to your local directory.

### 3. Configuration
1. Rename or save `sign.example.json` as `sign.json`.
2. Fill in the credentials as needed:
   - **HoYoLAB**: Log in to the [HoYoLAB Official Site](https://www.hoyolab.com/), open browser developer tools, and get `ltoken_v2`, `ltmid_v2`, and `ltuid_v2` from cookies.
   - **Skport**: Refer to the [How to Get Skport Credentials](#how-to-get-skport-credentials) section below (`profiles[].cred`).
   - **Skland**: See [How to Get Skland Token](#how-to-get-skland-token), then put it in `profiles[].token`.
3. Configure **Discord Webhook**:
   - Enter your Webhook URL in `display.discord.bots` (leave blank if not needed).
   - To enable message updating, set `reuse_msg` to `true`.

#### How to Get Skport Credentials
1. Install the **Violentmonkey** extension ([Official Site](https://violentmonkey.github.io/)).
2. Go to the [Script Link](https://github.com/cptmacp/blobs/raw/refs/heads/main/fetch_cred_user.js) and install/import it.
3. Open the [Endfield Sign-in Page](https://game.skport.com/endfield/sign-in?header=0&hg_media=skport&hg_link_campaign=tools) and wait a moment.
4. A window containing `cred` will pop up; copy it into `sign.json`.

#### How to Get Skland Token
1. Log in to [Hypergryph Passport](https://user.hypergryph.com/login), open `https://web-api.hypergryph.com/account/info/hg`, and copy the `content` field value as token.
2. Or log in to [Skland Web](https://www.skland.com/), open `https://web-api.skland.com/account/info/hg` and copy the `content` field value as token.
3. In this project, put the token into `profiles[].token` for the `platform: "skland"` profile.

### 4. Run the Script
Open PowerShell, navigate to the project directory, and execute:
```powershell
./sign.ps1
```

## Configuration Details

### Discord Bot Configuration (`bots`)
- `discord_name`: The display name of the bot.
- `reuse_msg`: 
    - `false`: Send a new message every time.
    - `true`: Automatically record the ID after the first message and update it in subsequent runs.
    - `[Message ID]`: Manually specify the message ID to update.
- `minimal`: Whether to enable minimal display (shows only reward abbreviations).
- `profiles`: A list where you can enter account indices (starting from `0`) or specific `console_name` values.

### Account Configuration (`profiles`)
- `platform`: `hoyolab`, `skport`, `skland`, or `fuhouse`.
- HoYoLAB credentials: `ltoken`/`ltoken_v2` and related cookie fields.
- Skport credentials: `cred` is required.
- Skland credentials: `token` is required.
- Fuhouse credentials: `cookies` (specifically `PHPSESSID` cookie) is required.
- `console_name`: A custom name used for log display and bot matching.

## Automation

You can use the built-in `sign_schedule.ps1` to automatically register a Windows **Task Scheduler** task:

1. Open PowerShell with **Administrator privileges**.
2. Run: `./sign_schedule.ps1`.
3. The script will automatically create a scheduled task named `AnimeAttendance`, set to run **daily at 00:00 (UTC+8)** and at **system startup**.

## Disclaimer

This project is for educational and exchange purposes only. Please do not use it for any commercial purposes. The user assumes all responsibility for any account issues (such as bans or anomalies) caused by using this tool.
