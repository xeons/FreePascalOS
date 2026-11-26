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
  Where per-origin data that outlives the process is kept: the Cache
  API's caches and the service worker registrations (with their
  scripts). A store asks for an origin's record of a kind when it first
  needs it and gives the whole record back after it changed.

  OriginDataBackend is the process's (nil: everything is kept in memory
  only). TFolderOriginData keeps each record as a file,
  Folder/Kind/<origin file name>, for a program that may write files (a
  browser running its pages itself, webbrowse); a sandboxed content
  process gets a backend that asks the browser instead.

  The records' contents are the stores' own; TOriginDataWriter and
  TOriginDataReader are the little-endian length-prefixed fields they
  are made of (a reader never reads past the end: a short record reads
  as empty fields and Failed is set).
}
unit Web.Storage.OriginData;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TOriginDataBackend = class
  public
    { The record of Kind ('caches', 'service-workers') for a serialized
      origin; empty when there is none. }
    function Load(const Kind, Origin: string): TBytes; virtual; abstract;
    { Empty Data removes the record. }
    procedure Save(const Kind, Origin: string; const Data: TBytes); virtual; abstract;
  end;

  { Files (thread safe: a browser's GUI thread and its network service
    use one). }
  TFolderOriginData = class(TOriginDataBackend)
  private
    FFolder: string;
    FLock: TRTLCriticalSection;
    function PathOf(const Kind, Origin: string): string;
  public
    constructor Create(const AFolder: string);
    destructor Destroy; override;
    function Load(const Kind, Origin: string): TBytes; override;
    procedure Save(const Kind, Origin: string; const Data: TBytes); override;
    property Folder: string read FFolder;
  end;

  { Records in memory only (private browsing; thread safe). }
  TMemoryOriginData = class(TOriginDataBackend)
  private
    FKeys: TStringList;
    FRecords: array of TBytes;
    FLock: TRTLCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    function Load(const Kind, Origin: string): TBytes; override;
    procedure Save(const Kind, Origin: string; const Data: TBytes); override;
    procedure Clear;
  end;

  TOriginDataWriter = class
  private
    FData: TBytes;
    FLength: Integer;
    procedure Append(const Source; Count: Integer);
  public
    procedure WriteInteger(Value: Int64);
    procedure WriteNumber(Value: Double);
    procedure WriteText(const Text: string);
    procedure WriteBytes(const Bytes: TBytes);
    function Data: TBytes;
  end;

  TOriginDataReader = class
  private
    FData: TBytes;
    FPosition: Integer;
    FFailed: Boolean;
    function Take(var Target; Count: Integer): Boolean;
  public
    constructor Create(const AData: TBytes);
    function ReadInteger: Int64;
    function ReadNumber: Double;
    function ReadText: string;
    function ReadBytes: TBytes;
    function AtEnd: Boolean;
    property Failed: Boolean read FFailed;
  end;

var
  OriginDataBackend: TOriginDataBackend;

{ An origin as a file name (https://example.com:8443 is
  https_example.com_8443). }
function OriginDataFileName(const Origin: string): string;

implementation

function OriginDataFileName(const Origin: string): string;
var
  Index: Integer;
begin
  Result := Origin;
  for Index := 1 to Length(Result) do
    if not (Result[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '-']) then
      Result[Index] := '_';
  while Pos('___', Result) > 0 do
    Delete(Result, Pos('___', Result), 2);
end;

constructor TFolderOriginData.Create(const AFolder: string);
begin
  inherited Create;
  FFolder := ExcludeTrailingPathDelimiter(AFolder);
  InitCriticalSection(FLock);
end;

destructor TFolderOriginData.Destroy;
begin
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

constructor TMemoryOriginData.Create;
begin
  inherited Create;
  FKeys := TStringList.Create;
  InitCriticalSection(FLock);
end;

destructor TMemoryOriginData.Destroy;
begin
  FKeys.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TMemoryOriginData.Load(const Kind, Origin: string): TBytes;
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := FKeys.IndexOf(Kind + ' ' + Origin);
    if Index >= 0 then
      Result := Copy(FRecords[Index])
    else
      Result := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOriginData.Save(const Kind, Origin: string; const Data: TBytes);
var
  Index: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Index := FKeys.IndexOf(Kind + ' ' + Origin);
    if Index < 0 then
    begin
      Index := FKeys.Add(Kind + ' ' + Origin);
      SetLength(FRecords, FKeys.Count);
    end;
    FRecords[Index] := Copy(Data);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TMemoryOriginData.Clear;
begin
  EnterCriticalSection(FLock);
  try
    FKeys.Clear;
    FRecords := nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TFolderOriginData.PathOf(const Kind, Origin: string): string;
begin
  Result := FFolder + '/' + Kind + '/' + OriginDataFileName(Origin) + '.dat';
end;

function ReadWholeFile(const Path: string): TBytes;
var
  Stream: TFileStream;
begin
  Result := nil;
  if not FileExists(Path) then
    Exit;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Result, Stream.Size);
      if Length(Result) > 0 then
        Stream.ReadBuffer(Result[0], Length(Result));
    finally
      Stream.Free;
    end;
  except
    on EStreamError do
      Result := nil;
  end;
end;

{ Written beside it first, then put in its place. }
procedure WriteWholeFile(const Path: string; const Data: TBytes);
var
  Stream: TFileStream;
  Temporary: string;
begin
  Temporary := Path + '.new';
  try
    Stream := TFileStream.Create(Temporary, fmCreate);
    try
      Stream.WriteBuffer(Data[0], Length(Data));
    finally
      Stream.Free;
    end;
    if FileExists(Path) then
      DeleteFile(Path);
    RenameFile(Temporary, Path);
  except
    on EStreamError do
      ;
  end;
end;

function TFolderOriginData.Load(const Kind, Origin: string): TBytes;
begin
  EnterCriticalSection(FLock);
  try
    Result := ReadWholeFile(PathOf(Kind, Origin));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TFolderOriginData.Save(const Kind, Origin: string; const Data: TBytes);
var
  Path: string;
begin
  EnterCriticalSection(FLock);
  try
    Path := PathOf(Kind, Origin);
    if Length(Data) = 0 then
    begin
      if FileExists(Path) then
        DeleteFile(Path);
    end
    else
    begin
      ForceDirectories(FFolder + '/' + Kind);
      WriteWholeFile(Path, Data);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TOriginDataWriter.Append(const Source; Count: Integer);
begin
  if Count <= 0 then
    Exit;
  if FLength + Count > Length(FData) then
    SetLength(FData, (FLength + Count) * 2 + 64);
  Move(Source, FData[FLength], Count);
  Inc(FLength, Count);
end;

procedure TOriginDataWriter.WriteInteger(Value: Int64);
begin
  Value := NtoLE(Value);
  Append(Value, SizeOf(Value));
end;

procedure TOriginDataWriter.WriteNumber(Value: Double);
var
  Bits: Int64 absolute Value;
begin
  WriteInteger(Bits);
end;

procedure TOriginDataWriter.WriteText(const Text: string);
begin
  WriteInteger(Length(Text));
  if Length(Text) > 0 then
    Append(Text[1], Length(Text));
end;

procedure TOriginDataWriter.WriteBytes(const Bytes: TBytes);
begin
  WriteInteger(Length(Bytes));
  if Length(Bytes) > 0 then
    Append(Bytes[0], Length(Bytes));
end;

function TOriginDataWriter.Data: TBytes;
begin
  Result := Copy(FData, 0, FLength);
end;

constructor TOriginDataReader.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
end;

function TOriginDataReader.Take(var Target; Count: Integer): Boolean;
begin
  Result := not FFailed and (Count >= 0) and (FPosition + Count <= Length(FData));
  if not Result then
  begin
    FFailed := True;
    Exit;
  end;
  if Count > 0 then
    Move(FData[FPosition], Target, Count);
  Inc(FPosition, Count);
end;

function TOriginDataReader.ReadInteger: Int64;
begin
  Result := 0;
  if Take(Result, SizeOf(Result)) then
    Result := LEtoN(Result)
  else
    Result := 0;
end;

function TOriginDataReader.ReadNumber: Double;
var
  Bits: Int64;
  Value: Double absolute Bits;
begin
  Bits := ReadInteger;
  Result := Value;
end;

function TOriginDataReader.ReadText: string;
var
  Count: Int64;
begin
  Result := '';
  Count := ReadInteger;
  if FFailed or (Count < 0) or (Count > Length(FData) - FPosition) then
  begin
    FFailed := True;
    Exit;
  end;
  SetLength(Result, Count);
  if Count > 0 then
    Take(Result[1], Count);
end;

function TOriginDataReader.ReadBytes: TBytes;
var
  Count: Int64;
begin
  Result := nil;
  Count := ReadInteger;
  if FFailed or (Count < 0) or (Count > Length(FData) - FPosition) then
  begin
    FFailed := True;
    Exit;
  end;
  SetLength(Result, Count);
  if Count > 0 then
    Take(Result[0], Count);
end;

function TOriginDataReader.AtEnd: Boolean;
begin
  Result := FFailed or (FPosition >= Length(FData));
end;

end.
