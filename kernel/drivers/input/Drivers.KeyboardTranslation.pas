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
  From keys to characters, for every keyboard driver.

  Keys are numbered as in scan code set 1 (what the PS/2 controller
  delivers), with Extended for the keys that come after an E0 prefix;
  other keyboards (USB) map their key codes onto these. Each keyboard
  has its own TKeyboardState: the modifiers held, the locks, and a dead
  key waiting for its letter.

  Characters follow the layout (Drivers.KeyboardLayouts): Shift and Caps
  Lock for capitals, AltGr (the right Alt key) for the third character
  of a key, Ctrl with a letter for control characters (Ctrl-C is 3), dead
  keys putting their accent on the next letter, and the arrow, Home, End,
  Insert and Delete keys as the escape sequences a terminal sends
  (ESC [ A, ...). With Num Lock on the numeric keypad gives digits, with
  it off the cursor and editing keys printed on it. Characters beyond
  ASCII go out in UTF-8, as bytes of the keyboard's input device.

  Every press and release is also an input event (Io.InputEvents): its
  key code, the modifiers, and the character it typed. While a program
  has taken the input, the characters do not go to the input device (the
  console) at all.
}
unit Drivers.KeyboardTranslation;

{$mode objfpc}

interface

uses
  Io.InputDevice;

const
  { What KeyboardLights returns, in the PS/2 keyboard's bit order. }
  LightScrollLock = $01;
  LightNumLock = $02;
  LightCapsLock = $04;

type
  TKeyboardState = record
    Input: PInputDevice;
    ShiftPressed: Boolean;
    ControlPressed: Boolean;
    AltGrPressed: Boolean;
    CapsLockOn: Boolean;
    NumLockOn: Boolean;
    ScrollLockOn: Boolean;
    { A dead key's accent waiting for the next character, 0 if none. }
    PendingAccent: LongWord;
    KeyCount: QWord;
    { Left Alt (AltGr is the right one). }
    AltPressed: Boolean;
    { The keyboard's number in input events, and what the key being
      handled typed (0 if nothing, or a sequence). }
    Source: Word;
    TypedCharacter: LongWord;
    SendingSequence: Boolean;
  end;

procedure InitializeKeyboardState(out State: TKeyboardState; Input: PInputDevice);
{ Handles the press or release of a key. Returns True if a lock key
  changed the locks (the keyboard's lights should follow). }
function TranslateKey(var State: TKeyboardState; Code: Byte; Extended, Released: Boolean): Boolean;
function KeyboardLights(const State: TKeyboardState): Byte;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Io.InputEvents,
  Drivers.KeyboardLayouts;

const
  KeyEscape = #27;

  ScanLeftShift = $2A;
  ScanRightShift = $36;
  ScanControl = $1D;
  ScanAlt = $38;
  ScanCapsLock = $3A;
  ScanNumLock = $45;
  ScanScrollLock = $46;
  ScanFirstKeypad = $47;
  ScanLastKeypad = $53;

  { The numeric keypad, 0x47-0x53, with Num Lock on. }
  KeypadDigits: array[ScanFirstKeypad..ScanLastKeypad] of Char = (
    '7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.');

procedure InitializeKeyboardState(out State: TKeyboardState; Input: PInputDevice);
begin
  FillMemory(@State, SizeOf(State), 0);
  State.Input := Input;
  State.Source := NewInputSource;
  { Num Lock starts on, as most firmware leaves it. }
  State.NumLockOn := True;
end;

function KeyboardLights(const State: TKeyboardState): Byte;
begin
  Result := 0;
  if State.ScrollLockOn then
    Result := Result or LightScrollLock;
  if State.NumLockOn then
    Result := Result or LightNumLock;
  if State.CapsLockOn then
    Result := Result or LightCapsLock;
end;

{ --- Delivering characters ------------------------------------------------ }

procedure DeliverCharacter(var State: TKeyboardState; Character: Char);
begin
  if not State.SendingSequence and (Byte(Character) < $80) then
    State.TypedCharacter := Byte(Character);
  if not InputIsTaken then
    AddInputByte(State.Input^, Byte(Character));
end;

{ A sequence (the escape sequence of an arrow key, say): no character
  for the event. }
procedure DeliverText(var State: TKeyboardState; Text: PChar);
begin
  State.SendingSequence := True;
  while Text^ <> #0 do
  begin
    DeliverCharacter(State, Text^);
    Inc(Text);
  end;
  State.SendingSequence := False;
end;

procedure DeliverUtf8(var State: TKeyboardState; CodePoint: LongWord); forward;

procedure DeliverCodePoint(var State: TKeyboardState; CodePoint: LongWord);
begin
  DeliverUtf8(State, CodePoint);
  State.TypedCharacter := CodePoint;
end;

procedure DeliverUtf8(var State: TKeyboardState; CodePoint: LongWord);
begin
  if CodePoint < $80 then
    DeliverCharacter(State, Char(CodePoint))
  else if CodePoint < $800 then
  begin
    DeliverCharacter(State, Char($C0 or (CodePoint shr 6)));
    DeliverCharacter(State, Char($80 or (CodePoint and $3F)));
  end
  else
  begin
    DeliverCharacter(State, Char($E0 or (CodePoint shr 12)));
    DeliverCharacter(State, Char($80 or ((CodePoint shr 6) and $3F)));
    DeliverCharacter(State, Char($80 or (CodePoint and $3F)));
  end;
end;

{ A waiting accent goes out by itself (the next key was not a letter it
  goes on). }
procedure FlushPendingAccent(var State: TKeyboardState);
begin
  if State.PendingAccent <> 0 then
  begin
    DeliverCodePoint(State, State.PendingAccent);
    State.PendingAccent := 0;
  end;
end;

{ The cursor and editing keys, from the separate block (after E0) or
  from the keypad with Num Lock off. }
procedure DeliverEditingKey(var State: TKeyboardState; Code: Byte);
begin
  FlushPendingAccent(State);
  case Code of
    $48: DeliverText(State, KeyEscape + '[A');   { up }
    $50: DeliverText(State, KeyEscape + '[B');   { down }
    $4D: DeliverText(State, KeyEscape + '[C');   { right }
    $4B: DeliverText(State, KeyEscape + '[D');   { left }
    $47: DeliverText(State, KeyEscape + '[H');   { home }
    $4F: DeliverText(State, KeyEscape + '[F');   { end }
    $52: DeliverText(State, KeyEscape + '[2~');  { insert }
    $53: DeliverText(State, KeyEscape + '[3~');  { delete }
    $49: DeliverText(State, KeyEscape + '[5~');  { page up }
    $51: DeliverText(State, KeyEscape + '[6~');  { page down }
  end;
end;

procedure HandleExtendedKey(var State: TKeyboardState; Code: Byte);
begin
  case Code of
    $1C:
      begin
        FlushPendingAccent(State);
        DeliverCharacter(State, #13);   { keypad enter }
      end;
    $35:
      begin
        FlushPendingAccent(State);
        DeliverCharacter(State, '/');   { keypad slash }
      end;
  else
    DeliverEditingKey(State, Code);
  end;
end;

procedure HandleKeypadKey(var State: TKeyboardState; Code: Byte);
begin
  { Minus and plus are the same either way. }
  if State.NumLockOn or (KeypadDigits[Code] = '-') or (KeypadDigits[Code] = '+') then
  begin
    FlushPendingAccent(State);
    DeliverCharacter(State, KeypadDigits[Code]);
  end
  else
    DeliverEditingKey(State, Code);
end;

{ A character key's code point (perhaps a dead key's) at the level the
  modifiers and Caps Lock choose. }
function CharacterOfKey(var State: TKeyboardState; Code: Byte): LongWord;
var
  UseShifted: Boolean;
begin
  Result := 0;
  if State.AltGrPressed then
    Result := LayoutCharacter(Code, LevelAltGr);
  if Result <> 0 then
    Exit;
  { Caps Lock works like Shift, for letters only. }
  UseShifted := State.ShiftPressed;
  if State.CapsLockOn and KeyIsCapsLockable(Code) then
    UseShifted := not UseShifted;
  if UseShifted then
    Result := LayoutCharacter(Code, LevelShifted)
  else
    Result := LayoutCharacter(Code, LevelPlain);
end;

procedure HandleCharacterKey(var State: TKeyboardState; Code: Byte);
var
  CodePoint: LongWord;
  Composed: LongWord;
  Previous: LongWord;
begin
  CodePoint := CharacterOfKey(State, Code);
  if CodePoint = 0 then
    Exit;
  if (CodePoint and DeadKeyFlag) <> 0 then
  begin
    CodePoint := CodePoint and not DeadKeyFlag;
    { The same dead key twice gives its accent; another dead key gives
      the first one's and waits itself. }
    if State.PendingAccent <> 0 then
    begin
      Previous := State.PendingAccent;
      FlushPendingAccent(State);
      if Previous = CodePoint then
        Exit;
    end;
    State.PendingAccent := CodePoint;
    Exit;
  end;
  if State.ControlPressed then
  begin
    { Ctrl with a letter (or @[\]^_) gives the control character. }
    if (CodePoint >= Ord('a')) and (CodePoint <= Ord('z')) then
      CodePoint := CodePoint - Ord('a') + 1
    else if (CodePoint >= Ord('@')) and (CodePoint <= Ord('_')) then
      CodePoint := CodePoint - Ord('@')
    else
      Exit;
    FlushPendingAccent(State);
    DeliverCodePoint(State, CodePoint);
    Exit;
  end;
  if State.PendingAccent <> 0 then
  begin
    Composed := ComposeAccent(State.PendingAccent, CodePoint);
    if (Composed = 0) and (CodePoint = Ord(' ')) then
      Composed := State.PendingAccent;
    if Composed <> 0 then
    begin
      State.PendingAccent := 0;
      DeliverCodePoint(State, Composed);
      Exit;
    end;
    FlushPendingAccent(State);
  end;
  DeliverCodePoint(State, CodePoint);
end;

function ModifiersOf(const State: TKeyboardState): LongWord;
begin
  Result := 0;
  if State.ShiftPressed then
    Result := Result or ModifierShift;
  if State.ControlPressed then
    Result := Result or ModifierControl;
  if State.AltPressed then
    Result := Result or ModifierAlt;
  if State.AltGrPressed then
    Result := Result or ModifierAltGr;
  if State.CapsLockOn then
    Result := Result or ModifierCapsLock;
  if State.NumLockOn then
    Result := Result or ModifierNumLock;
  if State.ScrollLockOn then
    Result := Result or ModifierScrollLock;
end;

procedure ReportKeyEvent(var State: TKeyboardState; Code: Byte; Extended, Released: Boolean);
var
  Event: TAbiInputEvent;
begin
  FillMemory(@Event, SizeOf(Event), 0);
  Event.Kind := InputEventKey;
  Event.Source := State.Source;
  Event.Code := Code;
  if Extended then
    Event.Code := Event.Code or KeyCodeExtended;
  if not Released then
  begin
    Event.Value := 1;
    Event.Character := State.TypedCharacter;
  end;
  Event.Modifiers := ModifiersOf(State);
  AddInputEvent(Event);
end;

function TranslateKeyCharacters(var State: TKeyboardState; Code: Byte; Extended, Released: Boolean): Boolean;
forward;

function TranslateKey(var State: TKeyboardState; Code: Byte; Extended, Released: Boolean): Boolean;
begin
  State.TypedCharacter := 0;
  Result := TranslateKeyCharacters(State, Code, Extended, Released);
  { E0 2A and E0 B6 are fake shifts some keys send, not keys. }
  if not (Extended and ((Code = ScanLeftShift) or (Code = ScanRightShift))) then
    ReportKeyEvent(State, Code, Extended, Released);
end;

function TranslateKeyCharacters(var State: TKeyboardState; Code: Byte; Extended, Released: Boolean): Boolean;
begin
  Result := False;
  if Extended then
  begin
    { Right Ctrl is E0 1D, AltGr E0 38; E0 2A/B6 are fake shifts some
      keys send. }
    if Code = ScanControl then
      State.ControlPressed := not Released
    else if Code = ScanAlt then
      State.AltGrPressed := not Released
    else if not Released and (Code <> ScanLeftShift) and (Code <> ScanRightShift) then
    begin
      Inc(State.KeyCount);
      HandleExtendedKey(State, Code);
    end;
    Exit;
  end;

  case Code of
    ScanLeftShift, ScanRightShift:
      begin
        State.ShiftPressed := not Released;
        Exit;
      end;
    ScanControl:
      begin
        State.ControlPressed := not Released;
        Exit;
      end;
    ScanAlt:
      begin
        State.AltPressed := not Released;
        Exit;
      end;
    ScanCapsLock, ScanNumLock, ScanScrollLock:
      begin
        if Released then
          Exit;
        case Code of
          ScanCapsLock: State.CapsLockOn := not State.CapsLockOn;
          ScanNumLock: State.NumLockOn := not State.NumLockOn;
        else
          State.ScrollLockOn := not State.ScrollLockOn;
        end;
        Exit(True);
      end;
  end;
  if Released then
    Exit;
  Inc(State.KeyCount);
  if (Code >= ScanFirstKeypad) and (Code <= ScanLastKeypad) then
    HandleKeypadKey(State, Code)
  else
    HandleCharacterKey(State, Code);
end;

end.
