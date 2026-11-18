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
  The files and directories a client has open, by the handles SFTP gives
  it: four bytes naming a slot of the table, which holds the system's
  handle and the path (SETSTAT on a handle and READDIR need it).
}
unit Sftp.Handles;

{$mode objfpc}{$H+}

interface

const
  { The process has 64 handles; three are standard ones. }
  MaximumOpenHandles = 48;

type
  TSftpHandleKind = (SftpFile, SftpDirectory);

  TSftpOpenHandle = record
    InUse: Boolean;
    Kind: TSftpHandleKind;
    SystemHandle: Int64;
    Path: string;
  end;
  PSftpOpenHandle = ^TSftpOpenHandle;

  TSftpHandleTable = class
  private
    FSlots: array[0..MaximumOpenHandles - 1] of TSftpOpenHandle;
  public
    destructor Destroy; override;
    { The client's handle text; '' when the table is full. }
    function Add(Kind: TSftpHandleKind; SystemHandle: Int64; const Path: string): string;
    { The slot named by Text of Kind; nil when there is none. }
    function Find(const Text: string; Kind: TSftpHandleKind): PSftpOpenHandle;
    { Closes the system's handle and frees the slot; False when Text
      names nothing. }
    function Close(const Text: string): Boolean;
  end;

implementation

uses
  Sys.Files,
  Ssh.Wire;

destructor TSftpHandleTable.Destroy;
var
  Index: Integer;
begin
  for Index := 0 to MaximumOpenHandles - 1 do
    if FSlots[Index].InUse then
      CloseFile(FSlots[Index].SystemHandle);
  inherited Destroy;
end;

function TSftpHandleTable.Add(Kind: TSftpHandleKind; SystemHandle: Int64; const Path: string): string;
var
  Index: Integer;
begin
  for Index := 0 to MaximumOpenHandles - 1 do
    if not FSlots[Index].InUse then
    begin
      FSlots[Index].InUse := True;
      FSlots[Index].Kind := Kind;
      FSlots[Index].SystemHandle := SystemHandle;
      FSlots[Index].Path := Path;
      Exit(SshUInt32(LongWord(Index)));
    end;
  Result := '';
end;

function SlotIndex(const Text: string): Integer;
var
  Value: LongWord;
begin
  Result := -1;
  if Length(Text) <> 4 then
    Exit;
  Value := ReadBigEndian32(Text, 1);
  if Value < MaximumOpenHandles then
    Result := Integer(Value);
end;

function TSftpHandleTable.Find(const Text: string; Kind: TSftpHandleKind): PSftpOpenHandle;
var
  Index: Integer;
begin
  Result := nil;
  Index := SlotIndex(Text);
  if (Index >= 0) and FSlots[Index].InUse and (FSlots[Index].Kind = Kind) then
    Result := @FSlots[Index];
end;

function TSftpHandleTable.Close(const Text: string): Boolean;
var
  Index: Integer;
begin
  Index := SlotIndex(Text);
  Result := (Index >= 0) and FSlots[Index].InUse;
  if not Result then
    Exit;
  CloseFile(FSlots[Index].SystemHandle);
  FSlots[Index].InUse := False;
  FSlots[Index].Path := '';
end;

end.
