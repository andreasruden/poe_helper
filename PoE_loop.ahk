; If pixel detection is glitchy: try adding ", Alt" or ", Slow" (without "") after PixelGetColor
; Press Ctrl-9 and Ctrl-0 to set the pixel reading up, only done once

; CONFIG:
iniKeys := {"DanceDelay": 1250, "FlaskDelay": 7200, "DanceBind": "r", "FlaskBinds": "3", "CombatOnlyFlaskBinds": "245", "UseAltPixelDetection": False, "UseSlowPixelDetection": false, "StanceOneX": -1, "StanceOneY": -1, "StanceOneColor": -1, "StanceTwoX": -1, "StanceTwoY": -1, "StanceTwoColor": -1, "ReadTownCd": 3000, "LogFilePath": "C:\Program Files (x86)\Grinding Gear Games\Path of Exile\logs\Client.txt", "DanceStdDev": 50, "DanceClamp": 150, "FlaskStdDev": 150, "FlaskClamp": 450, "SpamDelay": 70, "SpamStdDev": 7, "SpamTries": 10, "FlasksEnabled": true, "DanceEnabled": false, "ChatX": -1, "ChatY": -1, "ChatColor": -1, "MovementBinds": "LButton,q,a", "CombatBinds": "RButton,w,e,s,Space", "Recently": 1000, "DetonateDeadEnabled": False, "DetonateDeadTrigger": "d", "DesecrateBind": "RButton", "DetonateDeadBind": "s", "DesecrateCastsPerSecond": 2.5, "DetonateDeadCastsPerSecond": 1.5}

; Data
danceMemeCd := 0
flasksCd := 0
combatFlasksCd := 0
readTownCd := 0
lastTick := A_TickCount
inTown := true
stanceOne := [-1, -1, -1] ; X, Y, color
stanceTwo := [-1, -1, -1] ; X, Y, color
paused := true
combatBindTick := 0
movementBindTick := 0
heldCombatKeys := []
heldMovementKeys := []
ddStage := 0
ddCd := 0
ddKeyDown := false

ReadConfig()

Loop
{
    Sleep, 20
    
    if (lastTick > A_TickCount)
    {
        MsgBox, Wrap-around of tick-count. Closing script.
        ExitApp
    }
    
    if (readTownCd <= A_TickCount)
    {
        ReadLastZone()
        readTownCd := NewCd(iniKeys["ReadTownCd"], 0)
    }
        
    ; Execute expired events
    UpdateFlasks()
    UpdateDance()
    UpdateDetonateDead()
    
    ; Update key releases after events
    UpdateHeldKeys()
}

UpdateFlasks()
{
    global iniKeys, flasksCd, combatFlasksCd, combatBindTick, movementBindTickd
    flaskTick := A_TickCount
    if (iniKeys["FlasksEnabled"] && flasksCd <= flaskTick && (flaskTick <= combatBindTick || flaskTick <= movementBindTick))
    {
        flasksCd := NewCd(iniKeys["FlaskDelay"], iniKeys["FlaskStdDev"], iniKeys["FlaskClamp"])
        if (!IsActive())
            return
            
        playerFlaskBinds := Trim(iniKeys["FlaskBinds"])
        if (StrLen(playerFlaskBinds) > 0)
            Send, %playerFlaskBinds%
    }

    if (iniKeys["FlasksEnabled"] && combatFlasksCd <= flaskTick && flaskTick <= combatBindTick)
    {
        combatFlasksCd := NewCd(iniKeys["FlaskDelay"], iniKeys["FlaskStdDev"], iniKeys["FlaskClamp"])
        if (!IsActive())
            return
            
        playerFlaskBinds := Trim(iniKeys["CombatOnlyFlaskBinds"])
        if (StrLen(playerFlaskBinds) > 0)
            Send, %playerFlaskBinds%
    }
}

UpdateDance()
{
    global iniKeys, danceMemeCd, combatBindTick, movementBindTick
    danceTick := A_TickCount
    if (iniKeys["DanceEnabled"] && danceMemeCd <= danceTick && (danceTick <= combatBindTick || danceTick <= movementBindTick))
    {
        if (!IsActive())
        {
            danceMemeCd := NewCd(iniKeys["DanceDelay"], iniKeys["DanceStdDev"], iniKeys["DanceClamp"])
            return
        }
    
        ; Send bind & do Pixel detection for cooldown
        playerDanceBind := Trim(iniKeys["DanceBind"])
        detected := false
        tries := iniKeys["SpamTries"]
        Loop, %tries%
        {
            Send, %playerDanceBind%
            if (iniKeys["StanceOneX"] == -1 || iniKeys["StanceTwoX"] == -1)
                break
            if (!IsActive())
                break
            
            color1 := ReadPixel(iniKeys["StanceOneX"], iniKeys["StanceOneY"])
            color2 := ReadPixel(iniKeys["StanceTwoX"], iniKeys["StanceTwoY"])
            if (color1 == iniKeys["StanceOneColor"] || color2 == iniKeys["StanceTwoColor"])
            {
                detected := true
                break
            }
            
            slp := iniKeys["SpamDelay"] + NormalRand(0, iniKeys["SpamStdDev"])
            Sleep, %slp%
        }
        
        if (!detected && iniKeys["StanceOneX"] != -1 && iniKeys["StanceTwoX"] != -1)
            danceMemeCd := 3 * iniKeys["DanceDelay"] ; longer CD to indicate failure, will happen in loading screen
        else
            danceMemeCd := iniKeys["DanceDelay"]
            
        danceMemeCd := NewCd(danceMemeCd, iniKeys["DanceStdDev"], iniKeys["DanceClamp"])
    }
}

UpdateDetonateDead()
{
    global iniKeys, ddCd, ddStage, ddKeyDown, combatBindTick
    if (!iniKeys["DetonateDeadEnabled"] || !IsActive())
    {
        ddStage = 0
        ddCd = 0
        return
    }
    
    ddTick := A_TickCount
    if (ddTick < ddCd)
        return
    
    if (ddStage == 0)
    {
        if (!ddKeyDown)
            return
        
        ; Consider DD usage combat bind
        combatBindTick := A_TickCount + iniKeys["Recently"]
    
        ; Cast Desecrate
        desecrateBind := Trim(iniKeys["DesecrateBind"])
        if (StrLen(desecrateBind) > 0)
            Send, %desecrateBind%
        ct := CalcCastTime(iniKeys["DesecrateCastsPerSecond"])
        ddCd := NewCd(ct, 5, ct)
        ddStage := 1
    }
    else if (ddStage == 1)
    {
        ; Cast DD
        ddBind := Trim(iniKeys["DetonateDeadBind"])
        if (StrLen(ddBind) > 0)
            Send, %ddBind%
        ct := CalcCastTime(iniKeys["DetonateDeadCastsPerSecond"])
        ddCd := NewCd(ct, 5, ct)
        ddStage := 0
    }
}

NewCd(delay, dev, clamp := -1)
{
    add := delay + NormalRand(0, dev)
    if (clamp >= 0)
    {
        if (add > delay + clamp)
            add = delay + clamp
        else if (add < delay - clamp)
            add = delay - clamp
    }
    return A_TickCount + add
}

CalcCastTime(perSecond)
{
    return Ceil((1 / perSecond) * 1000)
}

IsActive()
{
    global paused, inTown
    if (paused)
        return false
    if (IsTyping())
        return false
    ; Wait if POE is not active app
    if (!WinActive("ahk_exe PathOfExile.exe"))
        return false
    ; Wait if we're in town/hideout
    if (inTown)
        return false
    return true
}

IsTyping()
{
    global iniKeys
    
    if (iniKeys["ChatX"] == -1)
        return false
    pixel := ReadPixel(iniKeys["ChatX"], iniKeys["ChatY"])
    return pixel == iniKeys["ChatColor"]
}

ReadLastZone()
{
    global iniKeys, inTown
    
    blockSize := 512
    f := FileOpen(iniKeys["LogFilePath"], "r")
    if (!IsObject(f))
    {
        MsgBox % "Failed opening " . iniKeys["LogFilePath"] . " Error: " . A_LastError . ". Exiting script."
        ExitApp
    }
    ptr := f.Length

    max := 50
    while (ptr > 0)
    {
        ; max := max - 1
        if (max <= 0)
        {
            MsgBox, Failed reading zone from POE log, exiting script.
            ExitApp
        }
        
        ptr := ptr - blockSize
        if (ptr < 0)
            ptr := 0
            
        f.Seek(ptr, SEEK_SET)
        partialFile := f.Read() ; read to end of file
        
        found := InStr(partialFile, "You have entered", false, 0)
        if (found != 0)
        {
            found := found + StrLen("You have entered")
            dot := InStr(partialFile, ".", false, found)
            if (dot == 0)
                return
            zone := Trim(SubStr(partialFile, found, dot - found))
            inTown := IsTown(zone)
            return
        }
    }
}

IsTown(zone)
{
    areas := ["Hideout", "Rogue Harbour", "Oriath Docks", "Highgate", "Sarn Encampment", "Bridge Encampment", "Lioneye's Watch", "Forest Encampment", "Overseer's Tower"]
    
    for _, area in areas
    {
        if (InStr(zone, area) != 0 && InStr(zone, "Syndicate Hideout") == 0)
            return true
    }
    
    return false
}

ReadConfig()
{
    global iniKeys
    for key, _ in iniKeys
    {
        IniRead, val, %A_MyDocuments%\PoE_loop.ini, Settings, %key%
        if (val == "ERROR")
        {
            WriteConfig()
            MsgBox % "Important!`nPlease edit " . A_MyDocuments . "\PoE_loop.ini before starting the script.`nPixel reading stances can be setup by using Ctrl-0 after starting the script.`nCtrl-9 sets up chat open detection.`nAlt-Mouse4 pauses/unpauses the script.`nScript will now close."
            ExitApp
        }
        iniKeys[key] := val
    }
    
    Hotkey, IfWinActive, ahk_exe PathOfExile.exe
    combatBinds := StrSplit(iniKeys["CombatBinds"], ",")
    movementBinds := StrSplit(iniKeys["MovementBinds"], ",")
    for _, keyName in combatBinds
    {
        Hotkey, $~%keyName%, CombatBindUsed, On ; hardware only, pass-through
    }
    for _, keyName in movementBinds
    {
        Hotkey, $~%keyName%, MovementBindUsed, On ; hardware only, pass-through
    }
    ddKeyName := iniKeys["DetonateDeadTrigger"]
    if (StrLen(ddKeyName) > 0 && iniKeys["DetonateDeadEnabled"])
    {
        HotKey, $~%ddKeyName%, DetonateDeadBindUsed, On ; hardware only, pass-through
    }
}

WriteConfig()
{
    global iniKeys
    for k, v in iniKeys
    {
        IniWrite, %v%, %A_MyDocuments%\PoE_loop.ini, Settings, %k%
    }
}

ReadPixel(x, y)
{
    if (iniKeys["UseSlowPixelDetection"])
        PixelGetColor, color, x, y, Slow
    else if (iniKeys["UseAltPixelDetection"])
        PixelGetColor, color, x, y, Alt
    else
        PixelGetColor, color, x, y
    return color
}

NormalRand(mean, stdDev)
{
    u1 := 0.0
    while (u1 <= 1.19209e-07) ; FLT_EPSILON: Step size of float, i.e., avoid u1 being 0 or too close to 0 for float arithmetics
    {
        Random, u1, 0.0, 1.0
    }
    Random, u2, 0.0, 1.0

    mag := stdDev * Sqrt(-2.0 * Ln(u1))
    z0 := mean + mag * Cos(2 * 3.14159265 * u2)
    ; z1 := mean + mag * Sin(2 * 3.14159265 * u2)
    Return Round(z0)
}

UpdateHeldKeys()
{
    global heldCombatKeys, heldMovementKeys, combatBindTick, movementBindTick, iniKeys, ddKeyDown
    
    for key, state in heldCombatKeys
    {
        if (state && !GetKeyState(key, "P"))
        {
            heldCombatKeys[key] := false
            combatBindTick := A_TickCount + iniKeys["Recently"]
        }
    }
    
    for key, state in heldMovementKeys
    {
        if (state && !GetKeyState(key, "P"))
        {
            heldMovementKeys[key] := false
            movementBindTick := A_TickCount + iniKeys["Recently"]
        }
    }
    
    if (ddKeyDown && !GetKeyState(iniKeys["DetonateDeadTrigger"], "P"))
    {
        ddKeyDown := false
    }
}

CombatBindUsed:
    myKey := A_ThisHotkey
    myKey := SubStr(myKey, 3) ; remove $~
    
    heldCombatKeys[myKey] := true
    combatBindTick := 2**32
return

MovementBindUsed:
    myKey := A_ThisHotkey
    myKey := SubStr(myKey, 3) ; remove $~
    
    heldMovementKeys[myKey] := true
    movementBindTick := 2**32
return

DetonateDeadBindUsed:
    ddKeyDown := true
return

^0::
    paused := true
    
    ; Stance One
    MsgBox, % "Pixel detection to notice when our attempt to activate stance 1 (e.g. sand stance) succeeds. Place cursor over the intended pixel (e.g. the stance icon as its cooldown just started) and then hit Tab"
    KeyWait, Tab, D
    MouseGetPos, x, y
    color := ReadPixel(x, y)
    Sleep, 100
    iniKeys["StanceOneX"] := x
    iniKeys["StanceOneY"] := y
    iniKeys["StanceOneColor"] := color
    
    ; Stance Two
    MsgBox, % "Pixel detection to notice when our attempt to activate stance 2 (e.g. blood stance) succeeds. Place cursor over the intended pixel (e.g. the stance icon as its cooldown just started) and then hit Tab"
    KeyWait, Tab, D
    MouseGetPos, x, y
    color := ReadPixel(x, y)
    Sleep, 100
    iniKeys["StanceTwoX"] := x
    iniKeys["StanceTwoY"] := y
    iniKeys["StanceTwoColor"] := color
    
    MsgBox % "Read color " . iniKeys["StanceOneColor"] . " for stance 1 at X=" . iniKeys["StanceOneX"] . ", Y=" . iniKeys["StanceOneY"] . "`nAnd color " . iniKeys["StanceTwoColor"] . " for stance 2 at X=" . iniKeys["StanceTwoX"] . ", Y=" . iniKeys["StanceTwoY"]
    WriteConfig()
    paused := false
return

^9::
    paused := true
    
    MsgBox, % "This will detect chat being open/closed. Place cursor over the intended pixel and then hit Tab"
    KeyWait, Tab, D
    MouseGetPos, x, y
    color := ReadPixel(x, y)
    Sleep, 100
    iniKeys["ChatX"] := x
    iniKeys["ChatY"] := y
    iniKeys["ChatColor"] := color
    
    MsgBox % "Read color " . iniKeys["ChatColor"] . " for stance 1 at X=" . iniKeys["ChatX"] . ", Y=" . iniKeys["ChatY"]
    WriteConfig()
    paused := false
return

#IfWinActive ahk_exe PathOfExile.exe
!XButton1::
    paused := !paused
	if (paused) {
		ToolTip, Loop OFF
	} else {
		ToolTip, Loop ON
	}
	SetTimer, RemoveToolTip, 1500
return

RemoveToolTip:
	SetTimer, RemoveToolTip, Off
	ToolTip
return
