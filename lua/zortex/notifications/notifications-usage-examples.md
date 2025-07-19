# Zortex Notification System - Usage Examples

## Basic Notifications

### Send an immediate notification
```lua
-- Simple notification
require("zortex").notify("Hello", "This is a test notification")

-- With options
require("zortex").notify("Important", "Check your calendar!", {
    priority = "high",
    sound = "bell",
    providers = {"system", "ntfy"}  -- Specific providers
})
```

### Schedule a notification
```lua
-- In 5 minutes
local id = require("zortex").features.notifications.schedule(
    "Reminder",
    "Time to take a break",
    "5m"  -- or os.time() + 300
)

-- Cancel it
require("zortex").features.notifications.cancel(id)
```

## Pomodoro Timer

### Basic Pomodoro workflow
```vim
" Start a work session
:ZortexPomodoroStart

" Check status
:ZortexPomodoroStatus

" Pause/Resume
:ZortexPomodoroPause
:ZortexPomodoroResume

" Skip to next phase
:ZortexPomodoroSkip

" Stop completely
:ZortexPomodoroStop
```

### Lua API
```lua
local pomodoro = require("zortex").pomodoro

-- Start work session
pomodoro.start()

-- Start specific phase
pomodoro.start("short_break")
pomodoro.start("long_break")

-- Get status
local status = pomodoro.status()
print(string.format("%s: %s remaining", 
    status.phase_name, 
    status.remaining_formatted
))
```

## Timers and Alarms

### Quick timer
```vim
" 25 minute timer
:ZortexTimerStart 25

" 5 minute timer with name
:ZortexTimerStart 5m Coffee break

" 2 hour timer
:ZortexTimerStart 2h Deep work session

" List active timers
:ZortexTimerList

" Stop a timer
:ZortexTimerStop timer_1234567890_123
```

### Set an alarm
```vim
" Alarm at 2:30 PM
:ZortexAlarmSet 14:30 Team meeting

" Alarm at 9 AM
:ZortexAlarmSet 9:00am Daily standup
```

### Lua API
```lua
local timer = require("zortex").timer

-- Start a timer with callback
local id = timer.start("30m", "Lunch timer", {
    title = "Lunch Time!",
    message = "Time to eat",
    sound = "bell",
    callback = function()
        print("Timer finished!")
    end
})

-- Check remaining time
local remaining = timer.get_remaining(id)
print(string.format("%d minutes left", remaining / 60))

-- Set an alarm
timer.alarm("15:00", "Coffee break", {
    message = "Time for afternoon coffee"
})
```

## Calendar Integration

### Calendar entries with notifications
```markdown
01-15-2024:
  - [ ] Team meeting @at(14:00) @notify(15m)
  - [ ] Doctor appointment @at(10:30) @notify(1h,30m)
  - Important deadline @notify(1d,2h,30m) @at(17:00)
```

### Sync calendar notifications
```vim
" Sync all calendar notifications
:ZortexNotificationSync

" Check for due notifications now
:ZortexNotificationCheck
```

## Keybindings

Default keybindings (with prefix `<leader>z`):
- `<leader>zp` - Start pomodoro
- `<leader>zP` - Pomodoro status  
- `<leader>zt` - Start 25min timer
- `<leader>zT` - List timers

## Configuration Examples

### Minimal config
```lua
notifications = {
    providers = {
        vim = { enabled = true },
        system = { enabled = true }
    }
}
```

### Full featured config
```lua
notifications = {
    enabled = true,
    check_interval_minutes = 1,
    
    providers = {
        system = {
            enabled = true,
            commands = {
                macos = "terminal-notifier -title '%s' -message '%s' -sound default",
                linux = "notify-send -u normal -t 10000 '%s' '%s'",
            }
        },
        ntfy = {
            enabled = true,
            topic = "my-zortex-notifications",
            priority = "high",
        },
        vim = {
            enabled = true,
            timeout = 10000,
        }
    },
    
    -- Different providers for different types
    calendar_providers = { "vim", "system", "ntfy" },
    pomodoro_providers = { "vim", "system" },
    timer_providers = { "vim" },
    
    pomodoro = {
        work_duration = 25,
        short_break = 5,
        long_break = 15,
        auto_start_break = true,
        sound = "bell"
    },
    
    timers = {
        warnings = { 300, 60, 30 }  -- Warnings at 5min, 1min, 30sec
    }
}
```

## Advanced Usage

### Custom notification handler
```lua
-- Send to specific providers only
require("zortex").notify("Build Complete", "Tests passed!", {
    providers = {"system", "ntfy"},
    priority = "high",
    tags = {"build", "success"},
    click_url = "http://ci.example.com/build/123"
})
```

### Integrating with other plugins
```lua
-- Example: Notify when long-running command completes
vim.api.nvim_create_autocmd("TermClose", {
    callback = function()
        require("zortex").notify(
            "Terminal Closed",
            "Command completed",
            { providers = {"system"} }
        )
    end
})
```

### Productivity workflow
```lua
-- Morning routine
local function morning_routine()
    local zortex = require("zortex")
    
    -- Schedule standup reminder
    zortex.features.notifications.schedule(
        "Standup Time",
        "Daily standup in 5 minutes",
        "9:25am"
    )
    
    -- Start first pomodoro
    zortex.pomodoro.start()
    
    -- Set lunch alarm
    zortex.timer.alarm("12:30", "Lunch break")
end
```