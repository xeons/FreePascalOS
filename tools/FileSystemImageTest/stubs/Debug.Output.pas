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
  Host stand-in for the kernel's debug output (FileSystemImageTest):
  shown only when ShowDebugOutput is set.
}
unit Debug.Output;

{$mode objfpc}

interface

var
  ShowDebugOutput: Boolean = False;

procedure DebugBeginMessage;
procedure DebugEndMessage;
procedure DebugWrite(Text: PChar);
procedure DebugWriteLine(Text: PChar);
procedure DebugWriteDecimal(Value: QWord);
procedure DebugWriteHex(Value: QWord; MinimumDigits: LongWord);
procedure DebugWriteTag(Component: PChar);

implementation

procedure DebugBeginMessage;
begin
end;

procedure DebugEndMessage;
begin
end;

procedure DebugWrite(Text: PChar);
begin
  if ShowDebugOutput then
    Write(Text);
end;

procedure DebugWriteLine(Text: PChar);
begin
  if ShowDebugOutput then
    WriteLn(Text);
end;

procedure DebugWriteDecimal(Value: QWord);
begin
  if ShowDebugOutput then
    Write(Value);
end;

procedure DebugWriteHex(Value: QWord; MinimumDigits: LongWord);
begin
  if ShowDebugOutput then
    Write(HexStr(Value, MinimumDigits));
end;

procedure DebugWriteTag(Component: PChar);
begin
  if ShowDebugOutput then
    Write('[', Component, '] ');
end;

end.
