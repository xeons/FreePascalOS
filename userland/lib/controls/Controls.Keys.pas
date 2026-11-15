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
  KeyF4 = $3E;
  KeyF10 = $44;
  KeyNumpadEnter = $1C or KeyCodeExtended;
  KeyHome = $47 or KeyCodeExtended;
  KeyArrowUp = $48 or KeyCodeExtended;
  KeyPageUp = $49 or KeyCodeExtended;
  KeyArrowLeft = $4B or KeyCodeExtended;
  KeyArrowRight = $4D or KeyCodeExtended;
  KeyEnd = $4F or KeyCodeExtended;
  KeyArrowDown = $50 or KeyCodeExtended;
  KeyPageDown = $51 or KeyCodeExtended;
  KeyDelete = $53 or KeyCodeExtended;

function IsEnterKey(Code: LongWord): Boolean;

implementation

function IsEnterKey(Code: LongWord): Boolean;
begin
  Result := (Code = KeyEnter) or (Code = KeyNumpadEnter);
end;

end.
