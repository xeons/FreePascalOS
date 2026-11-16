{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Keys for the whole desktop: keys the shell takes (RequestRegisterHotkey),
  which reach it whatever window is active - Ctrl+Shift+Escape opens the
  task manager even while a program that has stopped responding is
  active.

  A key is taken with the modifiers that must be held with it; pressed
  with exactly those (Shift, Ctrl, Alt and AltGr compared, the locks
  not), it goes to the shell as EventHotkey and no window hears of it,
  its release neither, so a program never sees half a key. The keys go
  when the shell does.
}
unit Server.Hotkeys;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

{ Takes (Take) or gives back the key Code with Modifiers for the shell. }
procedure SetHotkey(Code, Modifiers: LongWord; Take: Boolean);
{ The shell is gone: so are its keys. }
procedure ForgetHotkeys;
{ True if the key event is the shell's (it has been sent there): it must
  not go to the active window. }
function TakeHotkeyEvent(const Event: TAbiInputEvent): Boolean;

implementation

uses
  Windowing.Protocol,
  Server.Shell;

const
  MaximumHotkeys = 16;
  { The modifiers that tell one key combination from another. }
  ComparedModifiers = ModifierShift or ModifierControl or ModifierAlt or ModifierAltGr;
  NoKey = High(LongWord);

type
  THotkey = record
    Code: LongWord;
    Modifiers: LongWord;
  end;

var
  Hotkeys: array[0..MaximumHotkeys - 1] of THotkey;
  HotkeyCount: LongInt;
  { A key that was taken when pressed: its release is taken too. }
  HeldHotkeyCode: LongWord = NoKey;

function IndexOfHotkey(Code, Modifiers: LongWord): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to HotkeyCount - 1 do
    if (Hotkeys[Index].Code = Code) and (Hotkeys[Index].Modifiers = Modifiers) then
      Exit(Index);
  Result := -1;
end;

procedure SetHotkey(Code, Modifiers: LongWord; Take: Boolean);
var
  Index: LongInt;
begin
  Modifiers := Modifiers and ComparedModifiers;
  Index := IndexOfHotkey(Code, Modifiers);
  if Take and (Index < 0) and (HotkeyCount < MaximumHotkeys) then
  begin
    Hotkeys[HotkeyCount].Code := Code;
    Hotkeys[HotkeyCount].Modifiers := Modifiers;
    Inc(HotkeyCount);
  end
  else if not Take and (Index >= 0) then
  begin
    Hotkeys[Index] := Hotkeys[HotkeyCount - 1];
    Dec(HotkeyCount);
  end;
end;

procedure ForgetHotkeys;
begin
  HotkeyCount := 0;
  HeldHotkeyCode := NoKey;
end;

function TakeHotkeyEvent(const Event: TAbiInputEvent): Boolean;
var
  Message: TWindowMessage;
begin
  if Event.Value = 0 then
  begin
    Result := Event.Code = HeldHotkeyCode;
    if Result then
      HeldHotkeyCode := NoKey;
    Exit;
  end;
  if IndexOfHotkey(Event.Code, Event.Modifiers and ComparedModifiers) < 0 then
    Exit(False);
  HeldHotkeyCode := Event.Code;
  Message := NewMessage(EventHotkey, 0);
  Message.Code := Event.Code;
  Message.Modifiers := Event.Modifiers;
  SendToShell(Message);
  Result := True;
end;

end.
