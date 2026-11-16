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
  Adding, removing and changing user accounts: what useradd, userdel,
  usermod and the system settings service (for the Control Panel) all
  do, through these routines alone. They need root (the files are
  root's); each takes the account files' lock, reads the files, changes
  them and writes them back (Util.AccountFiles).

  A new user gets:
    - the next free id from 1000 (below 65534, nobody's), used as both
      user and group id when the group id is free too;
    - a group of the same name, their primary group ("user private
      groups": files they make are not shared by default);
    - a home in /home/NAME, theirs, mode 0755 like the first user's;
    - /bin/sh, and the password given (salted SHA-256 in /etc/shadow);
    - membership of "wheel", the administrators, when asked.

  Names are what the account files and paths can hold safely: a small
  letter, then small letters, digits, '_' or '-', 31 at most. A full
  name may not hold a colon or a line end.
}
unit Util.AccountChanges;

{$mode objfpc}
{$H+}

interface

const
  FirstUserId = 1000;
  NobodyId = 65534;
  MaximumUserNameLength = 31;
  HomeFolderRoot = '/home';
  DefaultShell = '/bin/sh';
  AdministratorsGroup = 'wheel';
  HomeFolderMode = $1ED; { rwxr-xr-x }

type
  TGroupNames = array of string;

function IsValidUserName(const Name: string): Boolean;
function IsValidFullName(const FullName: string): Boolean;

{ Each returns ErrorNone or an Abi error: ErrorInvalidArgument for a bad
  name, ErrorExists for a user (or group) already there, ErrorNotFound
  for no such user or group, ErrorNotPermitted for root's account,
  which cannot be removed. }
function AddUser(const Name, FullName: string; Password: PChar; Administrator: Boolean): LongInt;
function RemoveUser(const Name: string; RemoveHome: Boolean): LongInt;
function ChangePassword(const Name: string; Password: PChar): LongInt;
function ChangeFullName(const Name, FullName: string): LongInt;
{ The user's supplementary groups become exactly Groups (their primary
  group stays theirs whatever the list says). }
function ChangeGroups(const Name: string; const Groups: TGroupNames): LongInt;
{ The supplementary groups listing user Name. }
function SupplementaryGroupsOf(const Name: string): TGroupNames;
{ A comma separated list, as the group file and the service carry it. }
function SplitGroupList(const Text: string): TGroupNames;
function JoinGroupList(const Groups: TGroupNames): string;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Util.Numbers,
  Util.AccountFiles,
  Util.Accounts,
  Util.FileTree,
  Util.Passwords;

type
  { The three files, read under the lock. }
  TAccountTables = record
    Lock: Int64;
    Users: TAccountLines;
    Groups: TAccountLines;
    Shadow: TAccountLines;
  end;

function IntToText(Value: Int64): string;
begin
  Str(Value, Result);
end;

function IsValidUserName(const Name: string): Boolean;
var
  Index: Integer;
  Character: Char;
begin
  if (Length(Name) = 0) or (Length(Name) > MaximumUserNameLength) then
    Exit(False);
  if not (Name[1] in ['a'..'z']) then
    Exit(False);
  for Index := 2 to Length(Name) do
  begin
    Character := Name[Index];
    if not (Character in ['a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
  end;
  Result := True;
end;

function IsValidFullName(const FullName: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(FullName) do
    if FullName[Index] in [':', #10, #13] then
      Exit(False);
  Result := Length(FullName) <= 128;
end;

{ Takes the lock and reads the files; on an error nothing stays held. }
function OpenTables(out Tables: TAccountTables): LongInt;
begin
  Tables.Users := nil;
  Tables.Groups := nil;
  Tables.Shadow := nil;
  Tables.Lock := LockAccountFiles;
  if Tables.Lock < 0 then
    Exit(ErrorCodeOf(Tables.Lock));
  Result := ReadAccountFile(PasswordFilePath, Tables.Users);
  if Result = ErrorNone then
    Result := ReadAccountFile(GroupFilePath, Tables.Groups);
  if Result = ErrorNone then
  begin
    Result := ReadAccountFile(ShadowFilePath, Tables.Shadow);
    if Result = ErrorNotFound then
      Result := ErrorNone;
  end;
  if Result <> ErrorNone then
    UnlockAccountFiles(Tables.Lock);
end;

{ Writes the files back (the passwords last, so a user never has a
  password line without an account) and gives the lock up. }
function CloseTables(var Tables: TAccountTables; WriteThem: Boolean): LongInt;
begin
  Result := ErrorNone;
  if WriteThem then
  begin
    Result := WriteAccountFile(GroupFilePath, Tables.Groups, PublicAccountFileMode);
    if Result = ErrorNone then
      Result := WriteAccountFile(PasswordFilePath, Tables.Users, PublicAccountFileMode);
    if Result = ErrorNone then
      Result := WriteAccountFile(ShadowFilePath, Tables.Shadow, ShadowFileMode);
  end;
  UnlockAccountFiles(Tables.Lock);
end;

function IdOfLine(const Line: string): Int64;
var
  Fields: TAccountFields;
  Value: Int64;
begin
  Result := -1;
  Fields := SplitAccountLine(Line);
  if (Length(Fields) >= 3) and ParseDecimal(Fields[2], Value) then
    Result := Value;
end;

function IdIsTaken(const Lines: TAccountLines; Id: Int64): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Lines) do
    if IdOfLine(Lines[Index]) = Id then
      Exit(True);
  Result := False;
end;

{ The first id from FirstUserId free as a user id and as a group id. }
function NextFreeId(const Tables: TAccountTables): Int64;
begin
  Result := FirstUserId;
  while (Result < NobodyId) and (IdIsTaken(Tables.Users, Result) or IdIsTaken(Tables.Groups, Result)) do
    Inc(Result);
end;

{ The group line's members with Name added or taken away. }
function MembersWith(const Members: string; const Name: string; Present: Boolean): string;
var
  List: TGroupNames;
  Kept: TGroupNames;
  Index: Integer;
  Found: Boolean;
begin
  List := SplitGroupList(Members);
  Kept := nil;
  Found := False;
  for Index := 0 to High(List) do
  begin
    if List[Index] = Name then
    begin
      Found := True;
      if not Present then
        Continue;
    end;
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := List[Index];
  end;
  if Present and not Found then
  begin
    SetLength(Kept, Length(Kept) + 1);
    Kept[High(Kept)] := Name;
  end;
  Result := JoinGroupList(Kept);
end;

procedure SetMembership(var Groups: TAccountLines; LineIndex: Integer; const Name: string; Present: Boolean);
var
  Fields: TAccountFields;
begin
  Fields := SplitAccountLine(Groups[LineIndex]);
  if Length(Fields) < 4 then
    SetLength(Fields, 4);
  Fields[3] := MembersWith(Fields[3], Name, Present);
  Groups[LineIndex] := JoinAccountFields(Fields);
end;

function MakeHome(const Home: string; UserId, GroupId: LongWord): LongInt;
begin
  if not IsDirectory(HomeFolderRoot) then
  begin
    Result := CreateDirectory(HomeFolderRoot);
    if Result <> ErrorNone then
      Exit;
  end;
  Result := CreateDirectory(PChar(Home));
  { A home left behind by an earlier account of that name is taken over. }
  if Result = ErrorExists then
    Result := ErrorNone;
  if Result = ErrorNone then
    Result := ChangeOwner(PChar(Home), UserId, GroupId, False);
  if Result = ErrorNone then
    Result := ChangeMode(PChar(Home), HomeFolderMode);
end;

function AddUser(const Name, FullName: string; Password: PChar; Administrator: Boolean): LongInt;
var
  Tables: TAccountTables;
  Id: Int64;
  Home: string;
  WheelIndex: Integer;
begin
  if not IsValidUserName(Name) or not IsValidFullName(FullName) then
    Exit(ErrorInvalidArgument);
  Result := OpenTables(Tables);
  if Result <> ErrorNone then
    Exit;
  if (FindAccountLine(Tables.Users, Name) >= 0) or (FindAccountLine(Tables.Groups, Name) >= 0) then
  begin
    CloseTables(Tables, False);
    Exit(ErrorExists);
  end;
  Id := NextFreeId(Tables);
  if Id >= NobodyId then
  begin
    CloseTables(Tables, False);
    Exit(ErrorNoSpace);
  end;
  Home := HomeFolderRoot + '/' + Name;
  AppendAccountLine(Tables.Groups, Name + ':x:' + IntToText(Id) + ':');
  AppendAccountLine(Tables.Users, Name + ':x:' + IntToText(Id) + ':' + IntToText(Id) + ':' + FullName + ':' +
    Home + ':' + DefaultShell);
  PutPasswordInLines(Tables.Shadow, Name, Password);
  if Administrator then
  begin
    WheelIndex := FindAccountLine(Tables.Groups, AdministratorsGroup);
    if WheelIndex >= 0 then
      SetMembership(Tables.Groups, WheelIndex, Name, True);
  end;
  Result := CloseTables(Tables, True);
  if Result = ErrorNone then
    Result := MakeHome(Home, LongWord(Id), LongWord(Id));
end;

function RemoveUser(const Name: string; RemoveHome: Boolean): LongInt;
var
  Tables: TAccountTables;
  UserIndex: Integer;
  GroupIndex: Integer;
  Fields: TAccountFields;
  Home: string;
  Index: Integer;
  PrimaryGroupId: Int64;
  GroupStillUsed: Boolean;
begin
  Result := OpenTables(Tables);
  if Result <> ErrorNone then
    Exit;
  UserIndex := FindAccountLine(Tables.Users, Name);
  if UserIndex < 0 then
  begin
    CloseTables(Tables, False);
    Exit(ErrorNotFound);
  end;
  Fields := SplitAccountLine(Tables.Users[UserIndex]);
  if IdOfLine(Tables.Users[UserIndex]) = RootId then
  begin
    CloseTables(Tables, False);
    Exit(ErrorNotPermitted);
  end;
  Home := '';
  if Length(Fields) >= 6 then
    Home := Fields[5];
  PrimaryGroupId := -1;
  if (Length(Fields) >= 4) and not ParseDecimal(Fields[3], PrimaryGroupId) then
    PrimaryGroupId := -1;
  DeleteAccountLine(Tables.Users, UserIndex);
  DeleteAccountLine(Tables.Shadow, FindAccountLine(Tables.Shadow, Name));
  { Their own group goes with them, unless another user has it too. }
  GroupIndex := FindAccountLine(Tables.Groups, Name);
  if (GroupIndex >= 0) and (IdOfLine(Tables.Groups[GroupIndex]) = PrimaryGroupId) then
  begin
    GroupStillUsed := False;
    for Index := 0 to High(Tables.Users) do
    begin
      Fields := SplitAccountLine(Tables.Users[Index]);
      if (Length(Fields) >= 4) and (Fields[3] = IntToText(PrimaryGroupId)) then
        GroupStillUsed := True;
    end;
    if not GroupStillUsed then
      DeleteAccountLine(Tables.Groups, GroupIndex);
  end;
  for Index := 0 to High(Tables.Groups) do
    SetMembership(Tables.Groups, Index, Name, False);
  Result := CloseTables(Tables, True);
  { Only a home under /home is removed: never / or a shared folder. }
  if (Result = ErrorNone) and RemoveHome and (Copy(Home, 1, Length(HomeFolderRoot) + 1) = HomeFolderRoot + '/') and
     (Pos('..', Home) = 0) and IsDirectory(PChar(Home)) then
    if not RemoveTree(PChar(Home)) then
      Result := ErrorIo;
end;

function ChangePassword(const Name: string; Password: PChar): LongInt;
var
  Tables: TAccountTables;
begin
  Result := OpenTables(Tables);
  if Result <> ErrorNone then
    Exit;
  if FindAccountLine(Tables.Users, Name) < 0 then
  begin
    CloseTables(Tables, False);
    Exit(ErrorNotFound);
  end;
  PutPasswordInLines(Tables.Shadow, Name, Password);
  Result := CloseTables(Tables, True);
end;

function ChangeFullName(const Name, FullName: string): LongInt;
var
  Tables: TAccountTables;
  UserIndex: Integer;
  Fields: TAccountFields;
begin
  if not IsValidFullName(FullName) then
    Exit(ErrorInvalidArgument);
  Result := OpenTables(Tables);
  if Result <> ErrorNone then
    Exit;
  UserIndex := FindAccountLine(Tables.Users, Name);
  if UserIndex < 0 then
  begin
    CloseTables(Tables, False);
    Exit(ErrorNotFound);
  end;
  Fields := SplitAccountLine(Tables.Users[UserIndex]);
  if Length(Fields) < 7 then
    SetLength(Fields, 7);
  Fields[4] := FullName;
  Tables.Users[UserIndex] := JoinAccountFields(Fields);
  Result := CloseTables(Tables, True);
end;

function ListContains(const Groups: TGroupNames; const Name: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Groups) do
    if Groups[Index] = Name then
      Exit(True);
  Result := False;
end;

function ChangeGroups(const Name: string; const Groups: TGroupNames): LongInt;
var
  Tables: TAccountTables;
  Index: Integer;
  Fields: TAccountFields;
begin
  Result := OpenTables(Tables);
  if Result <> ErrorNone then
    Exit;
  if FindAccountLine(Tables.Users, Name) < 0 then
    Result := ErrorNotFound;
  for Index := 0 to High(Groups) do
    if FindAccountLine(Tables.Groups, Groups[Index]) < 0 then
      Result := ErrorNotFound;
  if Result <> ErrorNone then
  begin
    CloseTables(Tables, False);
    Exit;
  end;
  for Index := 0 to High(Tables.Groups) do
  begin
    Fields := SplitAccountLine(Tables.Groups[Index]);
    if Length(Fields) < 3 then
      Continue;
    SetMembership(Tables.Groups, Index, Name, ListContains(Groups, Fields[0]));
  end;
  Result := CloseTables(Tables, True);
end;

function SupplementaryGroupsOf(const Name: string): TGroupNames;
var
  Lines: TAccountLines;
  Index: Integer;
  Fields: TAccountFields;
begin
  Result := nil;
  if ReadAccountFile(GroupFilePath, Lines) <> ErrorNone then
    Exit;
  for Index := 0 to High(Lines) do
  begin
    Fields := SplitAccountLine(Lines[Index]);
    if (Length(Fields) >= 4) and ListContains(SplitGroupList(Fields[3]), Name) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Fields[0];
    end;
  end;
end;

function SplitGroupList(const Text: string): TGroupNames;
var
  Start: Integer;
  Position: Integer;
  Piece: string;
begin
  Result := nil;
  Start := 1;
  for Position := 1 to Length(Text) + 1 do
    if (Position > Length(Text)) or (Text[Position] = ',') then
    begin
      Piece := Copy(Text, Start, Position - Start);
      if Piece <> '' then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Piece;
      end;
      Start := Position + 1;
    end;
end;

function JoinGroupList(const Groups: TGroupNames): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Groups) do
  begin
    if Index > 0 then
      Result := Result + ',';
    Result := Result + Groups[Index];
  end;
end;

end.
