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
  Web Storage's storage areas (HTML Standard 12.2.1): an ordered map of
  string keys to string values with a quota of 5 MiB counted in UTF-16
  code units of keys and values, as the other browsers count it.

  TWebStorageArea keeps the pairs in insertion order (key(n) is stable
  until the area changes) with a hash index. A local storage area is
  backed by a file: Load reads it, changes set Dirty, SaveIfDirty writes
  it. The file is UTF-8 text, a pair per line: the key and the value
  escaped (backslash, tab and line breaks as \\, \t, \n and \r) and
  separated by a tab.

  TWebStorageRegistry hands out areas by origin: local ones loaded from
  and saved to a folder (a file per origin), session ones in memory.
}
unit Web.Storage;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  { The per-origin quota, in UTF-16 code units of keys plus values. }
  StorageQuota = 5 * 1024 * 1024;

type
  TWebStorageArea = class;

  { Where local storage really lives when it is not this process's (a
    browser's content process keeps it in the browser): fills a new
    area and hears every change made to it. }
  TWebStorageBackend = class
  public
    { Puts the origin's pairs into Area (with Area.LoadPair). }
    procedure LoadArea(const Origin: string; Area: TWebStorageArea); virtual; abstract;
    procedure ItemSet(const Origin, Key, Value: string); virtual; abstract;
    procedure ItemRemoved(const Origin, Key: string); virtual; abstract;
    procedure Cleared(const Origin: string); virtual; abstract;
  end;

  TWebStorageArea = class
  private
    FKeys: TStringList;
    FValues: TStringList;
    FIndex: TStringList;
    FUsage: Int64;
    FFileName: string;
    FDirty: Boolean;
    FBackend: TWebStorageBackend;
    FOrigin: string;
    function Find(const Key: string): Integer;
    procedure RebuildIndex;
  public
    constructor Create(const AFileName: string = '');
    destructor Destroy; override;
    { A pair as it was stored, told to nobody (filling the area). }
    procedure LoadPair(const Key, Value: string);
    function Count: Integer;
    function KeyAt(Index: Integer): string;
    { False when Key is not there. }
    function TryGet(const Key: string; out Value: string): Boolean;
    { False when the quota would be exceeded (nothing changes then). }
    function SetItem(const Key, Value: string): Boolean;
    procedure RemoveItem(const Key: string);
    procedure Clear;
    procedure Load;
    procedure SaveIfDirty;
    property Dirty: Boolean read FDirty;
    property FileName: string read FFileName;
  end;

  TWebStorageRegistry = class
  private
    FFolder: string;
    FLocal: TStringList;
    FSession: TStringList;
    FBackend: TWebStorageBackend;
  public
    { Folder: where local storage is kept ('' keeps it in memory only). }
    constructor Create(const AFolder: string);
    destructor Destroy; override;
    { The area of a serialized origin (a tuple origin, never 'null'). }
    function LocalArea(const Origin: string): TWebStorageArea;
    function SessionArea(const Origin: string): TWebStorageArea;
    { Writes the local areas that changed. }
    procedure SaveAll;
    { The file name for an origin (https://example.com:8443 becomes
      https_example.com_8443.txt). }
    class function OriginFileName(const Origin: string): string;
    property Folder: string read FFolder;
    { Local areas filled from and changes told to it (not owned; set
      before the first area is asked for). }
    property Backend: TWebStorageBackend read FBackend write FBackend;
  end;

{ The UTF-16 length of UTF-8 (WTF-8) text. }
function Utf16Length(const Text: string): Int64;

implementation

function Utf16Length(const Text: string): Int64;
var
  Index: Integer;
  Lead: Byte;
begin
  Result := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Lead := Ord(Text[Index]);
    if Lead < $80 then
      Inc(Index)
    else if Lead < $E0 then
      Inc(Index, 2)
    else if Lead < $F0 then
      Inc(Index, 3)
    else
    begin
      { A supplementary character is two code units. }
      Inc(Result);
      Inc(Index, 4);
    end;
    Inc(Result);
  end;
end;

function Escape(const Text: string): string;
var
  Index, Length_: Integer;
  Replacement: Char;
begin
  SetLength(Result, Length(Text) * 2);
  Length_ := 0;
  for Index := 1 to Length(Text) do
  begin
    case Text[Index] of
      '\': Replacement := '\';
      #9: Replacement := 't';
      #10: Replacement := 'n';
      #13: Replacement := 'r';
    else
      Replacement := #0;
    end;
    if Replacement <> #0 then
    begin
      Inc(Length_);
      Result[Length_] := '\';
      Inc(Length_);
      Result[Length_] := Replacement;
    end
    else
    begin
      Inc(Length_);
      Result[Length_] := Text[Index];
    end;
  end;
  SetLength(Result, Length_);
end;

function Unescape(const Text: string): string;
var
  Index, Length_: Integer;
  Character: Char;
begin
  SetLength(Result, Length(Text));
  Length_ := 0;
  Index := 1;
  while Index <= Length(Text) do
  begin
    Character := Text[Index];
    if (Character = '\') and (Index < Length(Text)) then
    begin
      Inc(Index);
      case Text[Index] of
        't': Character := #9;
        'n': Character := #10;
        'r': Character := #13;
      else
        Character := Text[Index];
      end;
    end;
    Inc(Length_);
    Result[Length_] := Character;
    Inc(Index);
  end;
  SetLength(Result, Length_);
end;

{ TWebStorageArea }

constructor TWebStorageArea.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FKeys := TStringList.Create;
  FValues := TStringList.Create;
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.CaseSensitive := True;
  FIndex.Duplicates := dupError;
end;

destructor TWebStorageArea.Destroy;
begin
  FKeys.Free;
  FValues.Free;
  FIndex.Free;
  inherited Destroy;
end;

function TWebStorageArea.Find(const Key: string): Integer;
var
  Position: Integer;
begin
  if FIndex.Find(Key, Position) then
    Result := PtrInt(FIndex.Objects[Position])
  else
    Result := -1;
end;

procedure TWebStorageArea.RebuildIndex;
var
  Index: Integer;
begin
  FIndex.Clear;
  for Index := 0 to FKeys.Count - 1 do
    FIndex.AddObject(FKeys[Index], TObject(PtrInt(Index)));
end;

procedure TWebStorageArea.LoadPair(const Key, Value: string);
var
  Backend: TWebStorageBackend;
begin
  Backend := FBackend;
  FBackend := nil;
  try
    SetItem(Key, Value);
  finally
    FBackend := Backend;
  end;
  FDirty := False;
end;

function TWebStorageArea.Count: Integer;
begin
  Result := FKeys.Count;
end;

function TWebStorageArea.KeyAt(Index: Integer): string;
begin
  if (Index < 0) or (Index >= FKeys.Count) then
    Exit('');
  Result := FKeys[Index];
end;

function TWebStorageArea.TryGet(const Key: string; out Value: string): Boolean;
var
  Index: Integer;
begin
  Value := '';
  Index := Find(Key);
  Result := Index >= 0;
  if Result then
    Value := FValues[Index];
end;

function TWebStorageArea.SetItem(const Key, Value: string): Boolean;
var
  Index: Integer;
  NewUsage: Int64;
begin
  Index := Find(Key);
  if Index >= 0 then
  begin
    if FValues[Index] = Value then
      Exit(True);
    NewUsage := FUsage - Utf16Length(FValues[Index]) + Utf16Length(Value);
    if NewUsage > StorageQuota then
      Exit(False);
    FValues[Index] := Value;
  end
  else
  begin
    NewUsage := FUsage + Utf16Length(Key) + Utf16Length(Value);
    if NewUsage > StorageQuota then
      Exit(False);
    FKeys.Add(Key);
    FValues.Add(Value);
    FIndex.AddObject(Key, TObject(PtrInt(FKeys.Count - 1)));
  end;
  FUsage := NewUsage;
  FDirty := True;
  Result := True;
  if FBackend <> nil then
    FBackend.ItemSet(FOrigin, Key, Value);
end;

procedure TWebStorageArea.RemoveItem(const Key: string);
var
  Index: Integer;
begin
  Index := Find(Key);
  if Index < 0 then
    Exit;
  FUsage := FUsage - Utf16Length(Key) - Utf16Length(FValues[Index]);
  FKeys.Delete(Index);
  FValues.Delete(Index);
  RebuildIndex;
  FDirty := True;
  if FBackend <> nil then
    FBackend.ItemRemoved(FOrigin, Key);
end;

procedure TWebStorageArea.Clear;
begin
  if FKeys.Count = 0 then
    Exit;
  FKeys.Clear;
  FValues.Clear;
  FIndex.Clear;
  FUsage := 0;
  FDirty := True;
  if FBackend <> nil then
    FBackend.Cleared(FOrigin);
end;

procedure TWebStorageArea.Load;
var
  Lines: TStringList;
  Index, Tab: Integer;
begin
  if (FFileName = '') or not FileExists(FFileName) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FFileName);
    except
      on EStreamError do
        Exit;
    end;
    for Index := 0 to Lines.Count - 1 do
    begin
      Tab := Pos(#9, Lines[Index]);
      if Tab > 0 then
        SetItem(Unescape(Copy(Lines[Index], 1, Tab - 1)), Unescape(Copy(Lines[Index], Tab + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
  FDirty := False;
end;

procedure TWebStorageArea.SaveIfDirty;
var
  Lines: TStringList;
  Index: Integer;
begin
  if not FDirty or (FFileName = '') then
    Exit;
  FDirty := False;
  if FKeys.Count = 0 then
  begin
    if FileExists(FFileName) then
      DeleteFile(FFileName);
    Exit;
  end;
  Lines := TStringList.Create;
  try
    for Index := 0 to FKeys.Count - 1 do
      Lines.Add(Escape(FKeys[Index]) + #9 + Escape(FValues[Index]));
    try
      ForceDirectories(ExtractFileDir(FFileName));
      Lines.SaveToFile(FFileName);
    except
      on EStreamError do
        FDirty := True;
    end;
  finally
    Lines.Free;
  end;
end;

{ TWebStorageRegistry }

constructor TWebStorageRegistry.Create(const AFolder: string);
begin
  inherited Create;
  FFolder := AFolder;
  FLocal := TStringList.Create;
  FLocal.Sorted := True;
  FLocal.OwnsObjects := True;
  FSession := TStringList.Create;
  FSession.Sorted := True;
  FSession.OwnsObjects := True;
end;

destructor TWebStorageRegistry.Destroy;
begin
  SaveAll;
  FLocal.Free;
  FSession.Free;
  inherited Destroy;
end;

class function TWebStorageRegistry.OriginFileName(const Origin: string): string;
var
  Index: Integer;
begin
  Result := Origin;
  for Index := 1 to Length(Result) do
    if not (Result[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '-']) then
      Result[Index] := '_';
  { "https://" became "https___". }
  Result := StringReplace(Result, '___', '_', []) + '.txt';
end;

function TWebStorageRegistry.LocalArea(const Origin: string): TWebStorageArea;
var
  Position: Integer;
  Path: string;
begin
  if FLocal.Find(Origin, Position) then
    Exit(TWebStorageArea(FLocal.Objects[Position]));
  if FFolder <> '' then
    Path := IncludeTrailingPathDelimiter(FFolder) + OriginFileName(Origin)
  else
    Path := '';
  Result := TWebStorageArea.Create(Path);
  Result.Load;
  if FBackend <> nil then
  begin
    FBackend.LoadArea(Origin, Result);
    Result.FOrigin := Origin;
    Result.FBackend := FBackend;
  end;
  FLocal.AddObject(Origin, Result);
end;

function TWebStorageRegistry.SessionArea(const Origin: string): TWebStorageArea;
var
  Position: Integer;
begin
  if FSession.Find(Origin, Position) then
    Exit(TWebStorageArea(FSession.Objects[Position]));
  Result := TWebStorageArea.Create;
  FSession.AddObject(Origin, Result);
end;

procedure TWebStorageRegistry.SaveAll;
var
  Index: Integer;
begin
  for Index := 0 to FLocal.Count - 1 do
    TWebStorageArea(FLocal.Objects[Index]).SaveIfDirty;
end;

end.
