; If pixel detection is glitchy: try adding ", Alt" or ", Slow" (without "") after PixelGetColor
; Press Ctrl-9 and Ctrl-0 to set the pixel reading up, only done once

; CONFIG:
iniKeys := {"FlaskDelay": 7200, "FlaskBinds": "3", "CombatOnlyFlaskBinds": "245", "UseAltPixelDetection": False, "UseSlowPixelDetection": false, "ReadTownCd": 3000, "LogFilePath": "C:\Program Files (x86)\Grinding Gear Games\Path of Exile\logs\Client.txt", "FlaskStdDev": 150, "FlaskClamp": 450, "SpamDelay": 70, "SpamStdDev": 7, "SpamTries": 10, "FlasksEnabled": true, "ChatX": -1, "ChatY": -1, "ChatColor": -1, "MovementBinds": "LButton,q,a", "CombatBinds": "RButton,w,e,s,Space", "Recently": 1000, "DetonateDeadEnabled": False, "DetonateDeadTrigger": "d", "DesecrateBind": "RButton", "DetonateDeadBind": "s", "DesecrateCastsPerSecond": 2.5, "DetonateDeadCastsPerSecond": 1.5}

; Data
flasksCd := 0
combatFlasksCd := 0
readTownCd := 0
lastTick := A_TickCount
inTown := true
paused := true
combatBindTick := 0
movementBindTick := 0
heldCombatKeys := []
heldMovementKeys := []
ddStage := 0
ddCd := 0
ddKeyDown := false

isLMBing := false
isTujen := false
tujenSlider := -1
tujenRetX := 0
tujenRetY := 0

ReadConfig()

Menu, TravelMenu, Add, &1 Kingsmarch, TravelKingsmarch
Menu, TravelMenu, Add, &2 Heist, TravelHeist
Menu, TravelMenu, Add, &3 Monastery, TravelMonastery
Menu, TravelMenu, Add, &4 Menagerie, TravelMenagerie
Menu, TravelMenu, Add, &5 Sanctum, TravelSanctum
Menu, TravelMenu, Add, &6 Delve, TravelDelve

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
    UpdateDetonateDead()

    ; Update key releases after events
    UpdateHeldKeys()
}

UpdateFlasks()
{
    global iniKeys, flasksCd, combatFlasksCd, combatBindTick, movementBindTick
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
    areas := ["Hideout", "Rogue Harbour", "Oriath Docks", "Highgate", "Sarn Encampment", "Bridge Encampment", "Lioneye's Watch", "Forest Encampment", "Overseer's Tower", "Monastery of the Keepers", "Kingsmarch", "The Sovereign"]

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
            MsgBox % "Important!`nPlease edit " . A_MyDocuments . "\PoE_loop.ini before starting the script.`nCtrl-9 sets up chat open detection.`nAlt-Mouse4 pauses/unpauses the script.`nScript will now close."
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

WriteToChat(msg)
{
	ClipSaved := ClipboardAll
	Clipboard := msg
	Send {Enter}^v{Enter}
	Clipboard := ClipSaved
	ClipSaved := ""
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

    MsgBox % "Read color " . iniKeys["ChatColor"] . " for chat detection at X=" . iniKeys["ChatX"] . ", Y=" . iniKeys["ChatY"]
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

$+F9::
	if !enabled
	{
		return
	}
	while GetKeyState("F9", "P")
	{
		Click
		Random, rand, 70, 120
		Sleep rand
	}
return

F1::
	WriteToChat("/exit")
return

F5::
	WriteToChat("/hideout")
return

F3::
	Menu, TravelMenu, Show
return

TravelKingsmarch:
	WriteToChat("/kingsmarch")
return

TravelHeist:
	WriteToChat("/heist")
return

TravelMonastery:
	WriteToChat("/monastery")
return

TravelMenagerie:
	WriteToChat("/menagerie")
return

TravelSanctum:
	WriteToChat("/sanctum")
return

TravelDelve:
	WriteToChat("/delve")
return

XButton1::
+XButton1::
^XButton1::
!A::
    global isLMBing
    isLMBing := !isLMBing
    if (isLMBing)
    {
        SetTimer, LeftClickSpam, 30
    }
    else
    {
        SetTimer, LeftClickSpam, Off
    }
return
LeftClickSpam:
    if (GetKeyState("ctrl", "P") || GetKeyState("shift", "P"))
    {
        Click
    }
	else if (GetKeyState("alt", "P"))
	{
		Click, Right
	}
return

^t::
    isTujen := !isTujen
    if (isTujen)
    {
		Hotkey, IfWinActive, ahk_exe PathOfExile.exe
		Hotkey, ~Right, TujenGamble, On
		Hotkey, ~Left, TujenReset, On
    }
    else
    {
        Hotkey, ~Right, TujenGamble, Off
		Hotkey, ~Left, TujenReset, Off
    }
return

TujenGamble:
	if (tujenSlider < 0)
	{
		MouseGetPos, tujenRetX, tujenRetY
		Click, Left ; Enter bid window
		Sleep, 100
		tujenSlider := 55
		MouseClickDrag, Left, 730, 800, 630, 800, 0
		MouseMove, 630, 860, 0
		Click, Left ; Accept
	}
	else if (tujenSlider == 55)
	{
		tujenSlider = 75
		MouseClickDrag, Left, 685, 800, 655, 800, 0
		MouseMove, 630, 860, 0
		Click, Left ; Accept
	}
	else if (tujenSlider == 75)
	{
		MouseMove, 630, 860, 0
		Click, Left ; Accept
	}
return

TujenReset:
	MouseMove, tujenRetX, tujenRetY
	tujenSlider := -1
return
