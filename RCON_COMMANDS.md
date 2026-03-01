## RCON Command Reference

### 📊 Server Info
- `info` — Get current world information  
- `Players` — List connected players (Name / SteamID)  
- `fetchbanned` — List banned SteamIDs  

### 🔄 Server Control
- `QuickRestart` — Restart server in 1 minute  
- `RestartNow` — Restart server immediately  
- `CancelRestart` — Cancel pending restart  
- `restart X` — Restart server in `X` minutes  
- `shutdown` — Shut down server  

### 💬 Admin Communication
- `admin MESSAGE` — Send admin chat message  

### 👤 Player Management
- `kick ID` — Kick player (SteamID)  
- `ban ID` — Ban and kick player  
- `unban ID` — Unban player  
- `teleport ID` — Teleport player to nearest spawn  
- `unstuck ID` — Unstuck player  

### 🌦 World Control
- `season X` — `spring` | `summer` | `autumn` | `winter`  
- `weather X` — `clear` | `partly_cloudy` | `overcast` | `foggy` | `light_rain` | `rain` | `thunder` | `light_snow` | `snow` | `blizzard`  