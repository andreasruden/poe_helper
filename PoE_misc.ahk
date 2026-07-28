WriteToChat(msg)
{
	ClipSaved := ClipboardAll
	Clipboard := msg
	Send {Enter}^v{Enter}
	Clipboard := ClipSaved
	ClipSaved := ""
}

#IfWinActive ahk_exe PathOfExile.exe
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

#IfWinActive ahk_exe PathOfExile.exe
F1::
	WriteToChat("/exit")
return

#IfWinActive ahk_exe PathOfExile.exe
F5::
	WriteToChat("/hideout")
return

#IfWinActive ahk_exe PathOfExile.exe
F6::
	WriteToChat("/kingsmarch")
return

#IfWinActive ahk_exe PathOfExile.exe
F7::
	WriteToChat("/heist")
return

#IfWinActive ahk_exe PathOfExile.exe
F8::
	WriteToChat("/monastery")
return

; Corrutping Fever
;#IfWinActive ahk_exe PathOfExile.exe
;$f::
;    Send, {Xbutton2}
;    Sleep, 100
;    Send, t
;    Sleep, 30
;    Send, {Xbutton2}
;return

;Gem swap
;#IfWinActive ahk_exe PathOfExile.exe
;^P::
;	MouseGetPos, x, y
;	Send, {i}
;	Click, 1432 371 Right
;	Sleep, 100
;	Click, 1432 371 Left
;	Sleep, 100
;	Send, {i}
;	MouseMove, x, y
;return

#IfWinActive ahk_exe PathOfExile.exe
isLMBing := false
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

isTujen := false
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

tujenSlider := -1
tujenRetX := 0
tujenRetY := 0

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
