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
  What a key press is to a page's KeyboardEvent (UI Events KeyboardEvent
  key and code values, and the legacy keyCode and charCode pages still
  read): the system's key codes are set 1 scan codes with
  KeyCodeExtended for the E0 keys; the character comes with the press.
}
unit WebView.KeyNames;

{$mode objfpc}
{$H+}

interface

type
  TDomKey = record
    { "a", "A", "Enter", "ArrowLeft" ... }
    Key: string;
    { "KeyA", "Enter", "ArrowLeft" ... ("" when unknown). }
    Code: string;
    { The legacy keyCode (Windows virtual key numbers). }
    KeyCode: LongWord;
    { 0 standard, 1 left, 2 right, 3 numpad. }
    Location: LongWord;
    { A key that types a character (keypress fires for it). }
    Printable: Boolean;
  end;

function DomKeyOf(ScanCode, Character: LongWord): TDomKey;
{ The character as UTF-8. }
function CodePointText(CodePoint: LongWord): string;
{ Dispatches a trusted KeyboardEvent (keydown, keypress, keyup) of the
  key at Target; False when the page cancelled it. Modifiers are the
  system's input modifier bits. }
function DispatchKeyEvent(Target: TObject; const EventType: string; ScanCode, Character, Modifiers: LongWord): Boolean;
{ Dispatches a trusted InputEvent "input" (inputType, data) at Target. }
procedure DispatchInputEvent(Target: TObject; const InputType, Data: string; HasData: Boolean);

implementation

uses
  SysUtils,
  Web.Dom.Events,
  Web.Dom.UiEvents;

const
  SystemShift = $01;
  SystemControl = $02;
  SystemAlt = $04;
  SystemSuper = $80;

function DomModifiers(Modifiers: LongWord): TModifierKeys;
begin
  Result := [];
  if (Modifiers and SystemShift) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierShift);
  if (Modifiers and SystemControl) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierControl);
  if (Modifiers and SystemAlt) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierAlt);
  if (Modifiers and SystemSuper) <> 0 then
    Include(Result, Web.Dom.UiEvents.ModifierMeta);
end;

function DispatchKeyEvent(Target: TObject; const EventType: string; ScanCode, Character, Modifiers: LongWord): Boolean;
var
  Event: TKeyboardEvent;
  Key: TDomKey;
begin
  Key := DomKeyOf(ScanCode, Character);
  Event := TKeyboardEvent.Create(EventType, True, True);
  try
    Event.IsTrusted := True;
    Event.Composed := True;
    Event.HasView := True;
    Event.Modifiers := DomModifiers(Modifiers);
    Event.Key := Key.Key;
    Event.Code := Key.Code;
    Event.Location := Key.Location;
    if EventType = 'keypress' then
    begin
      { keypress carries the character in both legacy fields. }
      if Key.Printable then
        Event.CharCode := Character
      else if Key.KeyCode = 13 then
        Event.CharCode := 13;
      Event.KeyCode := Event.CharCode;
    end
    else
      Event.KeyCode := Key.KeyCode;
    Result := TEventTarget(Target).DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

procedure DispatchInputEvent(Target: TObject; const InputType, Data: string; HasData: Boolean);
var
  Event: TInputEvent;
begin
  Event := TInputEvent.Create('input', True, False);
  try
    Event.IsTrusted := True;
    Event.Composed := True;
    Event.HasView := True;
    Event.InputType := InputType;
    Event.Data := Data;
    Event.HasData := HasData;
    TEventTarget(Target).DispatchEvent(Event);
  finally
    Event.Release;
  end;
end;

const
  KeyExtended = $100;

type
  TKeyRow = record
    ScanCode: Word;
    Code: string;
    Key: string;
    KeyCode: Byte;
    Location: Byte;
  end;

const
  { Key '' means the character typed names the key. }
  KeyRows: array[0..102] of TKeyRow = (
    (ScanCode: $01; Code: 'Escape'; Key: 'Escape'; KeyCode: 27; Location: 0),
    (ScanCode: $02; Code: 'Digit1'; Key: ''; KeyCode: 49; Location: 0),
    (ScanCode: $03; Code: 'Digit2'; Key: ''; KeyCode: 50; Location: 0),
    (ScanCode: $04; Code: 'Digit3'; Key: ''; KeyCode: 51; Location: 0),
    (ScanCode: $05; Code: 'Digit4'; Key: ''; KeyCode: 52; Location: 0),
    (ScanCode: $06; Code: 'Digit5'; Key: ''; KeyCode: 53; Location: 0),
    (ScanCode: $07; Code: 'Digit6'; Key: ''; KeyCode: 54; Location: 0),
    (ScanCode: $08; Code: 'Digit7'; Key: ''; KeyCode: 55; Location: 0),
    (ScanCode: $09; Code: 'Digit8'; Key: ''; KeyCode: 56; Location: 0),
    (ScanCode: $0A; Code: 'Digit9'; Key: ''; KeyCode: 57; Location: 0),
    (ScanCode: $0B; Code: 'Digit0'; Key: ''; KeyCode: 48; Location: 0),
    (ScanCode: $0C; Code: 'Minus'; Key: ''; KeyCode: 189; Location: 0),
    (ScanCode: $0D; Code: 'Equal'; Key: ''; KeyCode: 187; Location: 0),
    (ScanCode: $0E; Code: 'Backspace'; Key: 'Backspace'; KeyCode: 8; Location: 0),
    (ScanCode: $0F; Code: 'Tab'; Key: 'Tab'; KeyCode: 9; Location: 0),
    (ScanCode: $10; Code: 'KeyQ'; Key: ''; KeyCode: 81; Location: 0),
    (ScanCode: $11; Code: 'KeyW'; Key: ''; KeyCode: 87; Location: 0),
    (ScanCode: $12; Code: 'KeyE'; Key: ''; KeyCode: 69; Location: 0),
    (ScanCode: $13; Code: 'KeyR'; Key: ''; KeyCode: 82; Location: 0),
    (ScanCode: $14; Code: 'KeyT'; Key: ''; KeyCode: 84; Location: 0),
    (ScanCode: $15; Code: 'KeyY'; Key: ''; KeyCode: 89; Location: 0),
    (ScanCode: $16; Code: 'KeyU'; Key: ''; KeyCode: 85; Location: 0),
    (ScanCode: $17; Code: 'KeyI'; Key: ''; KeyCode: 73; Location: 0),
    (ScanCode: $18; Code: 'KeyO'; Key: ''; KeyCode: 79; Location: 0),
    (ScanCode: $19; Code: 'KeyP'; Key: ''; KeyCode: 80; Location: 0),
    (ScanCode: $1A; Code: 'BracketLeft'; Key: ''; KeyCode: 219; Location: 0),
    (ScanCode: $1B; Code: 'BracketRight'; Key: ''; KeyCode: 221; Location: 0),
    (ScanCode: $1C; Code: 'Enter'; Key: 'Enter'; KeyCode: 13; Location: 0),
    (ScanCode: $1D; Code: 'ControlLeft'; Key: 'Control'; KeyCode: 17; Location: 1),
    (ScanCode: $1E; Code: 'KeyA'; Key: ''; KeyCode: 65; Location: 0),
    (ScanCode: $1F; Code: 'KeyS'; Key: ''; KeyCode: 83; Location: 0),
    (ScanCode: $20; Code: 'KeyD'; Key: ''; KeyCode: 68; Location: 0),
    (ScanCode: $21; Code: 'KeyF'; Key: ''; KeyCode: 70; Location: 0),
    (ScanCode: $22; Code: 'KeyG'; Key: ''; KeyCode: 71; Location: 0),
    (ScanCode: $23; Code: 'KeyH'; Key: ''; KeyCode: 72; Location: 0),
    (ScanCode: $24; Code: 'KeyJ'; Key: ''; KeyCode: 74; Location: 0),
    (ScanCode: $25; Code: 'KeyK'; Key: ''; KeyCode: 75; Location: 0),
    (ScanCode: $26; Code: 'KeyL'; Key: ''; KeyCode: 76; Location: 0),
    (ScanCode: $27; Code: 'Semicolon'; Key: ''; KeyCode: 186; Location: 0),
    (ScanCode: $28; Code: 'Quote'; Key: ''; KeyCode: 222; Location: 0),
    (ScanCode: $29; Code: 'Backquote'; Key: ''; KeyCode: 192; Location: 0),
    (ScanCode: $2A; Code: 'ShiftLeft'; Key: 'Shift'; KeyCode: 16; Location: 1),
    (ScanCode: $2B; Code: 'Backslash'; Key: ''; KeyCode: 220; Location: 0),
    (ScanCode: $2C; Code: 'KeyZ'; Key: ''; KeyCode: 90; Location: 0),
    (ScanCode: $2D; Code: 'KeyX'; Key: ''; KeyCode: 88; Location: 0),
    (ScanCode: $2E; Code: 'KeyC'; Key: ''; KeyCode: 67; Location: 0),
    (ScanCode: $2F; Code: 'KeyV'; Key: ''; KeyCode: 86; Location: 0),
    (ScanCode: $30; Code: 'KeyB'; Key: ''; KeyCode: 66; Location: 0),
    (ScanCode: $31; Code: 'KeyN'; Key: ''; KeyCode: 78; Location: 0),
    (ScanCode: $32; Code: 'KeyM'; Key: ''; KeyCode: 77; Location: 0),
    (ScanCode: $33; Code: 'Comma'; Key: ''; KeyCode: 188; Location: 0),
    (ScanCode: $34; Code: 'Period'; Key: ''; KeyCode: 190; Location: 0),
    (ScanCode: $35; Code: 'Slash'; Key: ''; KeyCode: 191; Location: 0),
    (ScanCode: $36; Code: 'ShiftRight'; Key: 'Shift'; KeyCode: 16; Location: 2),
    (ScanCode: $37; Code: 'NumpadMultiply'; Key: ''; KeyCode: 106; Location: 3),
    (ScanCode: $38; Code: 'AltLeft'; Key: 'Alt'; KeyCode: 18; Location: 1),
    (ScanCode: $39; Code: 'Space'; Key: ''; KeyCode: 32; Location: 0),
    (ScanCode: $3A; Code: 'CapsLock'; Key: 'CapsLock'; KeyCode: 20; Location: 0),
    (ScanCode: $3B; Code: 'F1'; Key: 'F1'; KeyCode: 112; Location: 0),
    (ScanCode: $3C; Code: 'F2'; Key: 'F2'; KeyCode: 113; Location: 0),
    (ScanCode: $3D; Code: 'F3'; Key: 'F3'; KeyCode: 114; Location: 0),
    (ScanCode: $3E; Code: 'F4'; Key: 'F4'; KeyCode: 115; Location: 0),
    (ScanCode: $3F; Code: 'F5'; Key: 'F5'; KeyCode: 116; Location: 0),
    (ScanCode: $40; Code: 'F6'; Key: 'F6'; KeyCode: 117; Location: 0),
    (ScanCode: $41; Code: 'F7'; Key: 'F7'; KeyCode: 118; Location: 0),
    (ScanCode: $42; Code: 'F8'; Key: 'F8'; KeyCode: 119; Location: 0),
    (ScanCode: $43; Code: 'F9'; Key: 'F9'; KeyCode: 120; Location: 0),
    (ScanCode: $44; Code: 'F10'; Key: 'F10'; KeyCode: 121; Location: 0),
    (ScanCode: $45; Code: 'NumLock'; Key: 'NumLock'; KeyCode: 144; Location: 3),
    (ScanCode: $46; Code: 'ScrollLock'; Key: 'ScrollLock'; KeyCode: 145; Location: 0),
    (ScanCode: $47; Code: 'Numpad7'; Key: ''; KeyCode: 103; Location: 3),
    (ScanCode: $48; Code: 'Numpad8'; Key: ''; KeyCode: 104; Location: 3),
    (ScanCode: $49; Code: 'Numpad9'; Key: ''; KeyCode: 105; Location: 3),
    (ScanCode: $4A; Code: 'NumpadSubtract'; Key: ''; KeyCode: 109; Location: 3),
    (ScanCode: $4B; Code: 'Numpad4'; Key: ''; KeyCode: 100; Location: 3),
    (ScanCode: $4C; Code: 'Numpad5'; Key: ''; KeyCode: 101; Location: 3),
    (ScanCode: $4D; Code: 'Numpad6'; Key: ''; KeyCode: 102; Location: 3),
    (ScanCode: $4E; Code: 'NumpadAdd'; Key: ''; KeyCode: 107; Location: 3),
    (ScanCode: $4F; Code: 'Numpad1'; Key: ''; KeyCode: 97; Location: 3),
    (ScanCode: $50; Code: 'Numpad2'; Key: ''; KeyCode: 98; Location: 3),
    (ScanCode: $51; Code: 'Numpad3'; Key: ''; KeyCode: 99; Location: 3),
    (ScanCode: $52; Code: 'Numpad0'; Key: ''; KeyCode: 96; Location: 3),
    (ScanCode: $53; Code: 'NumpadDecimal'; Key: ''; KeyCode: 110; Location: 3),
    (ScanCode: $57; Code: 'F11'; Key: 'F11'; KeyCode: 122; Location: 0),
    (ScanCode: $58; Code: 'F12'; Key: 'F12'; KeyCode: 123; Location: 0),
    (ScanCode: $1C or KeyExtended; Code: 'NumpadEnter'; Key: 'Enter'; KeyCode: 13; Location: 3),
    (ScanCode: $1D or KeyExtended; Code: 'ControlRight'; Key: 'Control'; KeyCode: 17; Location: 2),
    (ScanCode: $35 or KeyExtended; Code: 'NumpadDivide'; Key: ''; KeyCode: 111; Location: 3),
    (ScanCode: $38 or KeyExtended; Code: 'AltRight'; Key: 'Alt'; KeyCode: 18; Location: 2),
    (ScanCode: $47 or KeyExtended; Code: 'Home'; Key: 'Home'; KeyCode: 36; Location: 0),
    (ScanCode: $48 or KeyExtended; Code: 'ArrowUp'; Key: 'ArrowUp'; KeyCode: 38; Location: 0),
    (ScanCode: $49 or KeyExtended; Code: 'PageUp'; Key: 'PageUp'; KeyCode: 33; Location: 0),
    (ScanCode: $4B or KeyExtended; Code: 'ArrowLeft'; Key: 'ArrowLeft'; KeyCode: 37; Location: 0),
    (ScanCode: $4D or KeyExtended; Code: 'ArrowRight'; Key: 'ArrowRight'; KeyCode: 39; Location: 0),
    (ScanCode: $4F or KeyExtended; Code: 'End'; Key: 'End'; KeyCode: 35; Location: 0),
    (ScanCode: $50 or KeyExtended; Code: 'ArrowDown'; Key: 'ArrowDown'; KeyCode: 40; Location: 0),
    (ScanCode: $51 or KeyExtended; Code: 'PageDown'; Key: 'PageDown'; KeyCode: 34; Location: 0),
    (ScanCode: $52 or KeyExtended; Code: 'Insert'; Key: 'Insert'; KeyCode: 45; Location: 0),
    (ScanCode: $53 or KeyExtended; Code: 'Delete'; Key: 'Delete'; KeyCode: 46; Location: 0),
    (ScanCode: $5B or KeyExtended; Code: 'MetaLeft'; Key: 'Meta'; KeyCode: 91; Location: 1),
    (ScanCode: $5C or KeyExtended; Code: 'MetaRight'; Key: 'Meta'; KeyCode: 92; Location: 2),
    (ScanCode: $5D or KeyExtended; Code: 'ContextMenu'; Key: 'ContextMenu'; KeyCode: 93; Location: 0),
    (ScanCode: $37 or KeyExtended; Code: 'PrintScreen'; Key: 'PrintScreen'; KeyCode: 44; Location: 0));

function CodePointText(CodePoint: LongWord): string;
begin
  if CodePoint < $80 then
    Result := Chr(CodePoint)
  else if CodePoint < $800 then
    Result := Chr($C0 or (CodePoint shr 6)) + Chr($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Result := Chr($E0 or (CodePoint shr 12)) + Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F))
  else
    Result := Chr($F0 or (CodePoint shr 18)) + Chr($80 or ((CodePoint shr 12) and $3F)) +
      Chr($80 or ((CodePoint shr 6) and $3F)) + Chr($80 or (CodePoint and $3F));
end;

function DomKeyOf(ScanCode, Character: LongWord): TDomKey;
var
  Index: Integer;
begin
  Result.Key := 'Unidentified';
  Result.Code := '';
  Result.KeyCode := 0;
  Result.Location := 0;
  Result.Printable := False;
  for Index := Low(KeyRows) to High(KeyRows) do
    if KeyRows[Index].ScanCode = ScanCode then
    begin
      Result.Code := KeyRows[Index].Code;
      Result.KeyCode := KeyRows[Index].KeyCode;
      Result.Location := KeyRows[Index].Location;
      Result.Key := KeyRows[Index].Key;
      Break;
    end;
  if (Character >= 32) and (Character <> 127) then
  begin
    Result.Key := CodePointText(Character);
    Result.Printable := True;
  end
  else if Result.Key = '' then
    Result.Key := 'Unidentified';
end;

end.
