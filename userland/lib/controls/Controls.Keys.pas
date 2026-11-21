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
  Key codes controls look at: set 1 scan codes, with KeyCodeExtended for
  the keys that come after an E0 prefix (input events carry them so).
}
unit Controls.Keys;

{$mode objfpc}

interface

uses
  Abi.SystemCalls;

const
  KeyEscape = $01;
  KeyBackspace = $0E;
  KeyTab = $0F;
  KeyEnter = $1C;
  { The left Alt key (the right one, AltGr, is $38 with KeyCodeExtended). }
  KeyAlt = $38;
  KeySpace = $39;
  KeyA = $1E;
  KeyC = $2E;
  KeyF = $21;
  KeyG = $22;
  KeyH = $23;
  KeyN = $31;
  KeyO = $18;
  KeyS = $1F;
  KeyV = $2F;
  KeyX = $2D;
  KeyY = $15;
  KeyZ = $2C;
  KeyD = $20;
  KeyL = $26;
  KeyB = $30;
  KeyE = $12;
  KeyI = $17;
  KeyJ = $24;
  KeyK = $25;
  KeyM = $32;
  KeyP = $19;
  KeyQ = $10;
  KeyR = $13;
  KeyT = $14;
  KeyU = $16;
  KeyW = $11;
  { The digits above the letters: Key1 to Key9 are $02 to $0A. }
  Key1 = $02;
  Key9 = $0A;
  Key0 = $0B;
  KeyMinus = $0C;
  KeyEquals = $0D;
  KeyNumpadMinus = $4A;
  KeyNumpadPlus = $4E;
  KeyF1 = $3B;
  KeyF2 = $3C;
  KeyF3 = $3D;
  KeyF4 = $3E;
  KeyF5 = $3F;
  KeyF6 = $40;
  KeyF7 = $41;
  KeyF10 = $44;
  KeyF11 = $57;
  KeyF12 = $58;
  KeyNumpadEnter = $1C or KeyCodeExtended;
  KeyHome = $47 or KeyCodeExtended;
  KeyArrowUp = $48 or KeyCodeExtended;
  KeyPageUp = $49 or KeyCodeExtended;
  KeyArrowLeft = $4B or KeyCodeExtended;
  KeyArrowRight = $4D or KeyCodeExtended;
  KeyEnd = $4F or KeyCodeExtended;
  KeyArrowDown = $50 or KeyCodeExtended;
  KeyPageDown = $51 or KeyCodeExtended;
  KeyInsert = $52 or KeyCodeExtended;
  KeyDelete = $53 or KeyCodeExtended;
  { The key that opens a context menu (beside the right Windows-logo
    key on PC keyboards). }
  KeyMenu = $5D or KeyCodeExtended;
  KeyLeftShift = $2A;
  KeyRightShift = $36;
  KeyLeftControl = $1D;
  KeyRightControl = $1D or KeyCodeExtended;

function IsEnterKey(Code: LongWord): Boolean;

implementation

function IsEnterKey(Code: LongWord): Boolean;
begin
  Result := (Code = KeyEnter) or (Code = KeyNumpadEnter);
end;

end.
