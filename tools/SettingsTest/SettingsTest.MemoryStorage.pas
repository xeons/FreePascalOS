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
  A settings storage in memory, for the host tests: each group's text
  and a version number that every write moves on. Several scopes may
  share one, as several programs share a folder. A group can be made
  unreadable (FailingGroup), as a damaged or forbidden file would be.
  Lock only counts, since the tests run in one thread; LockCount tells
  that writers took it.
}
unit SettingsTest.MemoryStorage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Storage;

type
  TMemoryStorage = class(TSettingsStorage)
  private
    FGroups: array of string;
    FTexts: array of string;
    FVersions: array of QWord;
    FNextVersion: QWord;
    FLocked: Boolean;
    function IndexOf(const Group: string): Integer;
  public
    FailingGroup: string;
    FailingError: LongInt;
    LockCount: Integer;
    WriteCount: Integer;
    function ReadGroup(const Group: string; out Text: string; out Version: TSettingsVersion): LongInt; override;
    function ReadVersion(const Group: string; out Version: TSettingsVersion): LongInt; override;
    function WriteGroup(const Group, Text: string): LongInt; override;
    function RemoveGroup(const Group: string): LongInt; override;
    function ListGroups(out Groups: TStringArray): LongInt; override;
    function Lock: LongInt; override;
    procedure Unlock; override;
    function Location: string; override;
    { The group's text ('' if none), for checking what was written. }
    function TextOf(const Group: string): string;
    function HasGroup(const Group: string): Boolean;
    { Puts text there as another program (or a person) would. }
    procedure Seed(const Group, Text: string);
  end;

implementation

uses
  Abi.SystemCalls;

function TMemoryStorage.IndexOf(const Group: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(FGroups) do
    if FGroups[Index] = Group then
      Exit(Index);
  Result := -1;
end;

function TMemoryStorage.ReadVersion(const Group: string; out Version: TSettingsVersion): LongInt;
var
  Index: Integer;
begin
  Version := Default(TSettingsVersion);
  Result := ErrorNone;
  Index := IndexOf(Group);
  if Index < 0 then
    Exit;
  Version.Exists := True;
  Version.NodeNumber := FVersions[Index];
  Version.Size := Length(FTexts[Index]);
end;

function TMemoryStorage.ReadGroup(const Group: string; out Text: string; out Version: TSettingsVersion): LongInt;
var
  Index: Integer;
begin
  Text := '';
  Version := Default(TSettingsVersion);
  if (FailingGroup <> '') and (Group = FailingGroup) then
    Exit(FailingError);
  Index := IndexOf(Group);
  if Index < 0 then
    Exit(ErrorNotFound);
  Text := FTexts[Index];
  Result := ReadVersion(Group, Version);
end;

function TMemoryStorage.WriteGroup(const Group, Text: string): LongInt;
var
  Index: Integer;
begin
  if not FLocked then
    raise Exception.Create('a group was written without the lock');
  Index := IndexOf(Group);
  if Index < 0 then
  begin
    Index := Length(FGroups);
    SetLength(FGroups, Index + 1);
    SetLength(FTexts, Index + 1);
    SetLength(FVersions, Index + 1);
    FGroups[Index] := Group;
  end;
  FTexts[Index] := Text;
  Inc(FNextVersion);
  FVersions[Index] := FNextVersion;
  Inc(WriteCount);
  Result := ErrorNone;
end;

function TMemoryStorage.RemoveGroup(const Group: string): LongInt;
var
  Index: Integer;
  Last: Integer;
begin
  Result := ErrorNone;
  Index := IndexOf(Group);
  if Index < 0 then
    Exit;
  Last := High(FGroups);
  FGroups[Index] := FGroups[Last];
  FTexts[Index] := FTexts[Last];
  FVersions[Index] := FVersions[Last];
  SetLength(FGroups, Last);
  SetLength(FTexts, Last);
  SetLength(FVersions, Last);
end;

function TMemoryStorage.ListGroups(out Groups: TStringArray): LongInt;
begin
  Groups := Copy(FGroups);
  Result := ErrorNone;
end;

function TMemoryStorage.Lock: LongInt;
begin
  if FLocked then
    raise Exception.Create('the lock was taken twice');
  FLocked := True;
  Inc(LockCount);
  Result := ErrorNone;
end;

procedure TMemoryStorage.Unlock;
begin
  FLocked := False;
end;

function TMemoryStorage.Location: string;
begin
  Result := 'memory';
end;

function TMemoryStorage.TextOf(const Group: string): string;
var
  Index: Integer;
begin
  Index := IndexOf(Group);
  if Index < 0 then
    Result := ''
  else
    Result := FTexts[Index];
end;

procedure TMemoryStorage.Seed(const Group, Text: string);
begin
  FLocked := True;
  WriteGroup(Group, Text);
  Dec(WriteCount);
  FLocked := False;
end;

function TMemoryStorage.HasGroup(const Group: string): Boolean;
begin
  Result := IndexOf(Group) >= 0;
end;

end.
