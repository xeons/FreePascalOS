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
  Directory routines of the FreePascalOS System unit (MkDir, RmDir,
  ChDir, GetDir).
}

procedure Do_MkDir(S: RawByteString);
begin
  if not FailedCall(SystemCall(CallCreateDirectory, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_RmDir(S: RawByteString);
var
  Information: TAbiFileInformation;
begin
  if S = '.' then
  begin
    InOutRes := 16;
    Exit;
  end;
  if FailedCall(SystemCall(CallGetPathInformation, QWord(PChar(S)), QWord(@Information), 0, 0, 0, 0)) then
    Exit;
  { RmDir removes directories only. }
  if Information.Kind <> KindDirectory then
  begin
    InOutRes := 5;
    Exit;
  end;
  if not FailedCall(SystemCall(CallRemove, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_ChDir(S: RawByteString);
begin
  if not FailedCall(SystemCall(CallSetCurrentDirectory, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0
  else if InOutRes = 2 then
    { A missing directory is "path not found", as in TP7. }
    InOutRes := 3;
end;

procedure Do_GetDir(DriveNr: Byte; var Dir: RawByteString);
var
  Buffer: array[0..4095] of Char;
begin
  Dir := '';
  if SystemCall(CallGetCurrentDirectory, QWord(@Buffer[0]), SizeOf(Buffer), 0, 0, 0, 0) >= 0 then
  begin
    Dir := Buffer;
    SetCodePage(Dir, DefaultFileSystemCodePage, False);
  end;
end;
