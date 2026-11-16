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
  Settings as a program sees them: the user's over the system's over the
  program's own defaults.

  Reading a setting looks in the user's scope, then in the system's, and
  gives the caller's default when neither has it. A value of another
  kind than the one asked for counts as no value (a hand-edited "Speed =
  fast" is not taken for a speed, and the system's speed is read
  instead).
  A value the system's scope marks fixed wins over the user's: that is
  how an administrator decides something for everyone.

  Writing goes to one scope, the user's unless told otherwise, and lasts
  once flushed (Flush, or freeing the object, which flushes). Deleting a
  key in the user's scope brings the system's value back.

  Paths are as Configuration.Names says ("Notepad/WordWrap"); a path
  that is not one reads as the default and is never written (Flush then
  says ErrorInvalidArgument).

  Not thread-safe: a thread that wants settings of its own opens its own
  object.

  Change notification: CheckForChanges calls OnChanged with every group
  someone else changed since this object read it. Today a program calls
  it when it wants (a timer, its window being activated); once the kernel
  watches folders for changes, a watch on both scopes' folders calls it
  as soon as a file changes, and programs need no change.
}
unit Configuration.Settings;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Values,
  Configuration.Names,
  Configuration.Scopes;

type
  TSettingsScopeKind = (ScopeUser, ScopeSystem);

  TSettingsChangedEvent = procedure(const Group: string) of object;

  TSettingValues = array of TSettingValue;

  TSettings = class
  private
    FScopes: array[TSettingsScopeKind] of TSettingsScope;
    FWriteError: LongInt;
    FOnChanged: TSettingsChangedEvent;
    function ScopeFor(Kind: TSettingsScopeKind): TSettingsScope;
    procedure NoteWriteError(Error: LongInt);
    { The values Path has that count, the one that wins first: the
      system's alone if it is fixed, else the user's and the system's. }
    function Candidates(const Path: string): TSettingValues;
  public
    { Takes both scopes over (frees them); either may be nil: no user
      (a service), or settings of one scope only. }
    constructor Create(UserScope, SystemScope: TSettingsScope);
    { Flushes, then frees the scopes. }
    destructor Destroy; override;

    { The value Path has, and the scope it comes from; False if neither
      scope has one. }
    function Lookup(const Path: string; out Value: TSettingValue; out Source: TSettingsScopeKind): Boolean;
    { The value in one scope only. }
    function LookupIn(Kind: TSettingsScopeKind; const Path: string; out Value: TSettingValue): Boolean;
    function ReadString(const Path: string; const Default: string): string;
    function ReadInteger(const Path: string; Default: Int64): Int64;
    { Read as ReadInteger, then kept within Lowest..Highest. }
    function ReadIntegerWithin(const Path: string; Default, Lowest, Highest: Int64): Int64;
    function ReadBoolean(const Path: string; Default: Boolean): Boolean;
    function ReadList(const Path: string; const Default: TStringArray): TStringArray;
    { True if the system's scope fixes Path's value. }
    function IsFixed(const Path: string): Boolean;

    procedure WriteValue(const Path: string; const Value: TSettingValue; Scope: TSettingsScopeKind = ScopeUser;
      Fixed: Boolean = False);
    procedure WriteString(const Path: string; const Value: string; Scope: TSettingsScopeKind = ScopeUser);
    procedure WriteInteger(const Path: string; Value: Int64; Scope: TSettingsScopeKind = ScopeUser);
    procedure WriteBoolean(const Path: string; Value: Boolean; Scope: TSettingsScopeKind = ScopeUser);
    procedure WriteList(const Path: string; const Value: TStringArray; Scope: TSettingsScopeKind = ScopeUser);
    { Deletes a key, or a whole section or group, from one scope. }
    procedure Delete(const Path: string; Scope: TSettingsScopeKind = ScopeUser);

    { The keys of a group or section, in both scopes (the user's first). }
    function ListKeys(const SectionPath: string): TStringArray;
    { The sections below a group or section in both scopes; '' lists the
      groups. }
    function ListSections(const SectionPath: string): TStringArray;
    { The same in one scope only. }
    function ListKeysIn(Kind: TSettingsScopeKind; const SectionPath: string): TStringArray;
    function ListSectionsIn(Kind: TSettingsScopeKind; const SectionPath: string): TStringArray;

    { Writes what was changed; ErrorNone or the first error. }
    function Flush: LongInt;
    { Calls OnChanged for each group that changed since it was read;
      True if any did. }
    function CheckForChanges: Boolean;

    function HasScope(Kind: TSettingsScopeKind): Boolean;
    property Scopes[Kind: TSettingsScopeKind]: TSettingsScope read ScopeFor;
    property OnChanged: TSettingsChangedEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  Abi.SystemCalls;

procedure AddMissing(var Names: TStringArray; const More: TStringArray);
var
  Index: Integer;
  Known: Integer;
  Present: Boolean;
begin
  for Index := 0 to High(More) do
  begin
    Present := False;
    for Known := 0 to High(Names) do
      if Names[Known] = More[Index] then
        Present := True;
    if not Present then
    begin
      SetLength(Names, Length(Names) + 1);
      Names[High(Names)] := More[Index];
    end;
  end;
end;

constructor TSettings.Create(UserScope, SystemScope: TSettingsScope);
begin
  inherited Create;
  FScopes[ScopeUser] := UserScope;
  FScopes[ScopeSystem] := SystemScope;
end;

destructor TSettings.Destroy;
var
  Kind: TSettingsScopeKind;
begin
  Flush;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    FScopes[Kind].Free;
  inherited Destroy;
end;

function TSettings.ScopeFor(Kind: TSettingsScopeKind): TSettingsScope;
begin
  Result := FScopes[Kind];
end;

function TSettings.HasScope(Kind: TSettingsScopeKind): Boolean;
begin
  Result := FScopes[Kind] <> nil;
end;

procedure TSettings.NoteWriteError(Error: LongInt);
begin
  if FWriteError = ErrorNone then
    FWriteError := Error;
end;

function TSettings.LookupIn(Kind: TSettingsScopeKind; const Path: string; out Value: TSettingValue): Boolean;
var
  Parsed: TSettingsPath;
  Fixed: Boolean;
begin
  Value := StringSetting('');
  if (FScopes[Kind] = nil) or not ParseKeyPath(Path, Parsed) then
    Exit(False);
  Result := FScopes[Kind].GetValue(Parsed, Value, Fixed);
end;

function TSettings.Lookup(const Path: string; out Value: TSettingValue; out Source: TSettingsScopeKind): Boolean;
var
  Parsed: TSettingsPath;
  SystemValue: TSettingValue;
  SystemFixed: Boolean;
  HasSystemValue: Boolean;
  UserFixed: Boolean;
begin
  Value := StringSetting('');
  Source := ScopeUser;
  if not ParseKeyPath(Path, Parsed) then
    Exit(False);
  HasSystemValue := (FScopes[ScopeSystem] <> nil) and
    FScopes[ScopeSystem].GetValue(Parsed, SystemValue, SystemFixed);
  if HasSystemValue and SystemFixed then
  begin
    Value := SystemValue;
    Source := ScopeSystem;
    Exit(True);
  end;
  { "fixed" means something only in the system's scope. }
  if (FScopes[ScopeUser] <> nil) and FScopes[ScopeUser].GetValue(Parsed, Value, UserFixed) then
    Exit(True);
  if HasSystemValue then
  begin
    Value := SystemValue;
    Source := ScopeSystem;
    Exit(True);
  end;
  Result := False;
end;

function TSettings.Candidates(const Path: string): TSettingValues;
var
  Parsed: TSettingsPath;
  Value: TSettingValue;
  Fixed: Boolean;
begin
  Result := nil;
  if not ParseKeyPath(Path, Parsed) then
    Exit;
  if (FScopes[ScopeSystem] <> nil) and FScopes[ScopeSystem].GetValue(Parsed, Value, Fixed) then
  begin
    SetLength(Result, 1);
    Result[0] := Value;
    if Fixed then
      Exit;
  end;
  if (FScopes[ScopeUser] <> nil) and FScopes[ScopeUser].GetValue(Parsed, Value, Fixed) then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Result[0];
    Result[0] := Value;
  end;
end;

function TSettings.ReadString(const Path: string; const Default: string): string;
var
  Values: TSettingValues;
  Index: Integer;
begin
  Values := Candidates(Path);
  for Index := 0 to High(Values) do
    if SettingAsString(Values[Index], Result) then
      Exit;
  Result := Default;
end;

function TSettings.ReadInteger(const Path: string; Default: Int64): Int64;
var
  Values: TSettingValues;
  Index: Integer;
begin
  Values := Candidates(Path);
  for Index := 0 to High(Values) do
    if SettingAsInteger(Values[Index], Result) then
      Exit;
  Result := Default;
end;

function TSettings.ReadIntegerWithin(const Path: string; Default, Lowest, Highest: Int64): Int64;
begin
  Result := ReadInteger(Path, Default);
  if Result < Lowest then
    Result := Lowest;
  if Result > Highest then
    Result := Highest;
end;

function TSettings.ReadBoolean(const Path: string; Default: Boolean): Boolean;
var
  Values: TSettingValues;
  Index: Integer;
begin
  Values := Candidates(Path);
  for Index := 0 to High(Values) do
    if SettingAsBoolean(Values[Index], Result) then
      Exit;
  Result := Default;
end;

function TSettings.ReadList(const Path: string; const Default: TStringArray): TStringArray;
var
  Values: TSettingValues;
  Index: Integer;
begin
  Values := Candidates(Path);
  for Index := 0 to High(Values) do
    if SettingAsList(Values[Index], Result) then
      Exit;
  Result := Copy(Default);
end;

function TSettings.IsFixed(const Path: string): Boolean;
var
  Parsed: TSettingsPath;
  Value: TSettingValue;
begin
  Result := False;
  if (FScopes[ScopeSystem] <> nil) and ParseKeyPath(Path, Parsed) then
    if not FScopes[ScopeSystem].GetValue(Parsed, Value, Result) then
      Result := False;
end;

procedure TSettings.WriteValue(const Path: string; const Value: TSettingValue; Scope: TSettingsScopeKind;
  Fixed: Boolean);
var
  Parsed: TSettingsPath;
begin
  if not ParseKeyPath(Path, Parsed) then
    NoteWriteError(ErrorInvalidArgument)
  else if FScopes[Scope] = nil then
    NoteWriteError(ErrorNotFound)
  else
    FScopes[Scope].SetValue(Parsed, Value, Fixed and (Scope = ScopeSystem));
end;

procedure TSettings.WriteString(const Path: string; const Value: string; Scope: TSettingsScopeKind);
begin
  WriteValue(Path, StringSetting(Value), Scope);
end;

procedure TSettings.WriteInteger(const Path: string; Value: Int64; Scope: TSettingsScopeKind);
begin
  WriteValue(Path, IntegerSetting(Value), Scope);
end;

procedure TSettings.WriteBoolean(const Path: string; Value: Boolean; Scope: TSettingsScopeKind);
begin
  WriteValue(Path, BooleanSetting(Value), Scope);
end;

procedure TSettings.WriteList(const Path: string; const Value: TStringArray; Scope: TSettingsScopeKind);
begin
  WriteValue(Path, ListSetting(Value), Scope);
end;

procedure TSettings.Delete(const Path: string; Scope: TSettingsScopeKind);
var
  Parsed: TSettingsPath;
begin
  { A path of two names or more may name a key or a section: both go. }
  if not ParseSectionPath(Path, Parsed) or (Parsed.Group = '') then
  begin
    NoteWriteError(ErrorInvalidArgument);
    Exit;
  end;
  if FScopes[Scope] = nil then
  begin
    NoteWriteError(ErrorNotFound);
    Exit;
  end;
  FScopes[Scope].Delete(Parsed);
  if ParseKeyPath(Path, Parsed) then
    FScopes[Scope].Delete(Parsed);
end;

function TSettings.ListKeysIn(Kind: TSettingsScopeKind; const SectionPath: string): TStringArray;
var
  Parsed: TSettingsPath;
begin
  Result := nil;
  if (FScopes[Kind] <> nil) and ParseSectionPath(SectionPath, Parsed) and (Parsed.Group <> '') then
    Result := FScopes[Kind].ListKeys(Parsed);
end;

function TSettings.ListSectionsIn(Kind: TSettingsScopeKind; const SectionPath: string): TStringArray;
var
  Parsed: TSettingsPath;
begin
  Result := nil;
  if (FScopes[Kind] <> nil) and ParseSectionPath(SectionPath, Parsed) then
    Result := FScopes[Kind].ListSections(Parsed);
end;

function TSettings.ListKeys(const SectionPath: string): TStringArray;
begin
  Result := ListKeysIn(ScopeUser, SectionPath);
  AddMissing(Result, ListKeysIn(ScopeSystem, SectionPath));
end;

function TSettings.ListSections(const SectionPath: string): TStringArray;
begin
  Result := ListSectionsIn(ScopeUser, SectionPath);
  AddMissing(Result, ListSectionsIn(ScopeSystem, SectionPath));
end;

function TSettings.Flush: LongInt;
var
  Kind: TSettingsScopeKind;
  Error: LongInt;
begin
  Result := FWriteError;
  FWriteError := ErrorNone;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if FScopes[Kind] <> nil then
    begin
      Error := FScopes[Kind].Flush;
      if (Error <> ErrorNone) and (Result = ErrorNone) then
        Result := Error;
    end;
end;

function TSettings.CheckForChanges: Boolean;
var
  Kind: TSettingsScopeKind;
  Changed: TStringArray;
  Everything: TStringArray;
  Index: Integer;
begin
  Everything := nil;
  for Kind := Low(TSettingsScopeKind) to High(TSettingsScopeKind) do
    if FScopes[Kind] <> nil then
    begin
      Changed := FScopes[Kind].CheckForChanges;
      AddMissing(Everything, Changed);
    end;
  Result := Length(Everything) > 0;
  if Assigned(FOnChanged) then
    for Index := 0 to High(Everything) do
      FOnChanged(Everything[Index]);
end;

end.
