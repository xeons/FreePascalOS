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
  The payloads of the network service's messages (WebIpc.Messages
  300..399): a content process's HTTP exchange ("hop": one request
  without its redirects, which the renderer's fetcher decides one by
  one) as plain values, so this unit needs no HTTP library; the content
  process and the browser turn them into libhttp's requests and back.
}
unit WebIpc.NetworkMessages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WebIpc.Wire;

type
  TIpcHeaderField = record
    Name: string;
    Value: string;
  end;

  TIpcHeaderFields = array of TIpcHeaderField;

  TIpcHopRequest = record
    HopId: QWord;
    Method: string;
    Url: string;
    Fields: TIpcHeaderFields;
    HasBody: Boolean;
    Body: TBytes;
    BodyType: string;
    PriorityUrgency: Byte;
    PriorityIncremental: Boolean;
    { libhttp's enumerations, as their ordinal values. }
    RedirectMode: Byte;
    MaximumRedirects: LongInt;
    CacheMode: Byte;
    CredentialsMode: Byte;
    DecodeContent: Boolean;
    { What the renderer says of the request's cookies; the browser checks
      SameSite against the site the process is locked to itself. }
    CookieSecure: Boolean;
    CookieSameSite: Boolean;
    CookieTopLevelNavigation: Boolean;
    CookieSafeMethod: Boolean;
    { Documents, style sheets, scripts, fonts: ahead of images. }
    Urgent: Boolean;
  end;

  TIpcHopHead = record
    HopId: QWord;
    Status: LongInt;
    Reason: string;
    Fields: TIpcHeaderFields;
    Url: string;
    FromCache: Boolean;
    Protocol: string;
  end;

  TIpcHopOutcome = record
    HopId: QWord;
    { THttpResultCode's ordinal value. }
    Code: LongInt;
    Text: string;
    ErrorCode: LongInt;
    Retryable: Boolean;
  end;

  TIpcLocalFile = record
    Found: Boolean;
    IsFolder: Boolean;
    Contents: TBytes;
    Error: string;
  end;

  TIpcStoragePairs = record
    Keys: TStringArray;
    Values: TStringArray;
  end;

function EncodeHopRequest(constref Value: TIpcHopRequest): TBytes;
function DecodeHopRequest(const Payload: TBytes): TIpcHopRequest;
function EncodeHopHead(constref Value: TIpcHopHead): TBytes;
function DecodeHopHead(const Payload: TBytes): TIpcHopHead;
function EncodeHopOutcome(constref Value: TIpcHopOutcome): TBytes;
function DecodeHopOutcome(const Payload: TBytes): TIpcHopOutcome;
{ A piece of a hop's body: its id, then the bytes. }
function EncodeHopData(HopId: QWord; Data: Pointer; Count: Integer): TBytes;
procedure DecodeHopData(const Payload: TBytes; out HopId: QWord; out Data: TBytes);
function EncodeHopId(HopId: QWord): TBytes;
function DecodeHopId(const Payload: TBytes): QWord;
function EncodeLocalFile(constref Value: TIpcLocalFile): TBytes;
function DecodeLocalFile(const Payload: TBytes): TIpcLocalFile;
function EncodeStoragePairs(constref Value: TIpcStoragePairs): TBytes;
function DecodeStoragePairs(const Payload: TBytes): TIpcStoragePairs;
{ A cookie request: the URL, the cookie (empty for a read) and the
  secure flag of the context. }
function EncodeCookieAccess(const Url, Cookie: string; Secure: Boolean): TBytes;
procedure DecodeCookieAccess(const Payload: TBytes; out Url, Cookie: string; out Secure: Boolean);
{ A storage change: origin, key, value (as many as the kind has). }
function EncodeStorageChange(const Origin, Key, Value: string): TBytes;
procedure DecodeStorageChange(const Payload: TBytes; out Origin, Key, Value: string);
{ IpcIndexedDbRequest: the client, the origin, the service request. }
function EncodeIndexedDbRequest(ClientId: LongWord; const Origin: string; const Request: TBytes): TBytes;
procedure DecodeIndexedDbRequest(const Payload: TBytes; out ClientId: LongWord; out Origin: string;
  out Request: TBytes);
{ IpcIndexedDbClientClosed and IpcIndexedDbNotice: the client and (a
  notice) the service's bytes. }
function EncodeIndexedDbNotice(ClientId: LongWord; const Notice: TBytes): TBytes;
procedure DecodeIndexedDbNotice(const Payload: TBytes; out ClientId: LongWord; out Notice: TBytes);

{ IpcOriginDataLoad and IpcOriginDataSave: the kind of record ('caches',
  'service-workers'), the origin and (saving) the record; the load's
  reply is EncodeOriginDataRecord. }
function EncodeOriginData(const Kind, Origin: string; const Data: TBytes): TBytes;
procedure DecodeOriginData(const Payload: TBytes; out Kind, Origin: string; out Data: TBytes);
function EncodeOriginDataRecord(const Data: TBytes): TBytes;
function DecodeOriginDataRecord(const Payload: TBytes): TBytes;

implementation

procedure WriteFields(Writer: TIpcWriter; const Fields: TIpcHeaderFields);
var
  Index: Integer;
begin
  Writer.WriteLongWord(Length(Fields));
  for Index := 0 to High(Fields) do
  begin
    Writer.WriteString(Fields[Index].Name);
    Writer.WriteString(Fields[Index].Value);
  end;
end;

function ReadFields(Reader: TIpcReader): TIpcHeaderFields;
var
  Count, Index: LongWord;
begin
  Result := nil;
  Count := Reader.ReadLongWord;
  if Count > LongWord(Reader.Remaining) div 8 then
    raise EIpcMalformed.Create('more header fields than the message holds');
  SetLength(Result, Count);
  Index := 0;
  while Index < Count do
  begin
    Result[Index].Name := Reader.ReadString;
    Result[Index].Value := Reader.ReadString;
    Inc(Index);
  end;
end;

function EncodeHopRequest(constref Value: TIpcHopRequest): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteQWord(Value.HopId);
    Writer.WriteString(Value.Method);
    Writer.WriteString(Value.Url);
    WriteFields(Writer, Value.Fields);
    Writer.WriteBoolean(Value.HasBody);
    Writer.WriteBytes(Value.Body);
    Writer.WriteString(Value.BodyType);
    Writer.WriteByte(Value.PriorityUrgency);
    Writer.WriteBoolean(Value.PriorityIncremental);
    Writer.WriteByte(Value.RedirectMode);
    Writer.WriteLongInt(Value.MaximumRedirects);
    Writer.WriteByte(Value.CacheMode);
    Writer.WriteByte(Value.CredentialsMode);
    Writer.WriteBoolean(Value.DecodeContent);
    Writer.WriteBoolean(Value.CookieSecure);
    Writer.WriteBoolean(Value.CookieSameSite);
    Writer.WriteBoolean(Value.CookieTopLevelNavigation);
    Writer.WriteBoolean(Value.CookieSafeMethod);
    Writer.WriteBoolean(Value.Urgent);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeHopRequest(const Payload: TBytes): TIpcHopRequest;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.HopId := Reader.ReadQWord;
    Result.Method := Reader.ReadString;
    Result.Url := Reader.ReadString;
    Result.Fields := ReadFields(Reader);
    Result.HasBody := Reader.ReadBoolean;
    Result.Body := Reader.ReadBytes;
    Result.BodyType := Reader.ReadString;
    Result.PriorityUrgency := Reader.ReadByte;
    Result.PriorityIncremental := Reader.ReadBoolean;
    Result.RedirectMode := Reader.ReadByte;
    Result.MaximumRedirects := Reader.ReadLongInt;
    Result.CacheMode := Reader.ReadByte;
    Result.CredentialsMode := Reader.ReadByte;
    Result.DecodeContent := Reader.ReadBoolean;
    Result.CookieSecure := Reader.ReadBoolean;
    Result.CookieSameSite := Reader.ReadBoolean;
    Result.CookieTopLevelNavigation := Reader.ReadBoolean;
    Result.CookieSafeMethod := Reader.ReadBoolean;
    Result.Urgent := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

function EncodeHopHead(constref Value: TIpcHopHead): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteQWord(Value.HopId);
    Writer.WriteLongInt(Value.Status);
    Writer.WriteString(Value.Reason);
    WriteFields(Writer, Value.Fields);
    Writer.WriteString(Value.Url);
    Writer.WriteBoolean(Value.FromCache);
    Writer.WriteString(Value.Protocol);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeHopHead(const Payload: TBytes): TIpcHopHead;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.HopId := Reader.ReadQWord;
    Result.Status := Reader.ReadLongInt;
    Result.Reason := Reader.ReadString;
    Result.Fields := ReadFields(Reader);
    Result.Url := Reader.ReadString;
    Result.FromCache := Reader.ReadBoolean;
    Result.Protocol := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

function EncodeHopOutcome(constref Value: TIpcHopOutcome): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteQWord(Value.HopId);
    Writer.WriteLongInt(Value.Code);
    Writer.WriteString(Value.Text);
    Writer.WriteLongInt(Value.ErrorCode);
    Writer.WriteBoolean(Value.Retryable);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeHopOutcome(const Payload: TBytes): TIpcHopOutcome;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.HopId := Reader.ReadQWord;
    Result.Code := Reader.ReadLongInt;
    Result.Text := Reader.ReadString;
    Result.ErrorCode := Reader.ReadLongInt;
    Result.Retryable := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

function EncodeHopData(HopId: QWord; Data: Pointer; Count: Integer): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteQWord(HopId);
    Writer.WriteRaw(Data, Count);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeHopData(const Payload: TBytes; out HopId: QWord; out Data: TBytes);
var
  Reader: TIpcReader;
begin
  Data := nil;
  Reader := TIpcReader.Create(Payload);
  try
    HopId := Reader.ReadQWord;
    SetLength(Data, Reader.Remaining);
    if Length(Data) > 0 then
      Reader.ReadRaw(@Data[0], Length(Data));
  finally
    Reader.Free;
  end;
end;

function EncodeHopId(HopId: QWord): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteQWord(HopId);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeHopId(const Payload: TBytes): QWord;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result := Reader.ReadQWord;
  finally
    Reader.Free;
  end;
end;

function EncodeLocalFile(constref Value: TIpcLocalFile): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Value.Found);
    Writer.WriteBoolean(Value.IsFolder);
    Writer.WriteBytes(Value.Contents);
    Writer.WriteString(Value.Error);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeLocalFile(const Payload: TBytes): TIpcLocalFile;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Found := Reader.ReadBoolean;
    Result.IsFolder := Reader.ReadBoolean;
    Result.Contents := Reader.ReadBytes;
    Result.Error := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

function EncodeStoragePairs(constref Value: TIpcStoragePairs): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteStrings(Value.Keys);
    Writer.WriteStrings(Value.Values);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeStoragePairs(const Payload: TBytes): TIpcStoragePairs;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Keys := Reader.ReadStrings;
    Result.Values := Reader.ReadStrings;
    if Length(Result.Keys) <> Length(Result.Values) then
      raise EIpcMalformed.Create('storage keys and values do not pair');
  finally
    Reader.Free;
  end;
end;

function EncodeCookieAccess(const Url, Cookie: string; Secure: Boolean): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Url);
    Writer.WriteString(Cookie);
    Writer.WriteBoolean(Secure);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeCookieAccess(const Payload: TBytes; out Url, Cookie: string; out Secure: Boolean);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Url := Reader.ReadString;
    Cookie := Reader.ReadString;
    Secure := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

function EncodeStorageChange(const Origin, Key, Value: string): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Origin);
    Writer.WriteString(Key);
    Writer.WriteString(Value);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeStorageChange(const Payload: TBytes; out Origin, Key, Value: string);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Origin := Reader.ReadString;
    Key := Reader.ReadString;
    Value := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

function EncodeIndexedDbRequest(ClientId: LongWord; const Origin: string; const Request: TBytes): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongWord(ClientId);
    Writer.WriteString(Origin);
    Writer.WriteBytes(Request);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeIndexedDbRequest(const Payload: TBytes; out ClientId: LongWord; out Origin: string;
  out Request: TBytes);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    ClientId := Reader.ReadLongWord;
    Origin := Reader.ReadString;
    Request := Reader.ReadBytes;
  finally
    Reader.Free;
  end;
end;

function EncodeIndexedDbNotice(ClientId: LongWord; const Notice: TBytes): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongWord(ClientId);
    Writer.WriteBytes(Notice);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeIndexedDbNotice(const Payload: TBytes; out ClientId: LongWord; out Notice: TBytes);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    ClientId := Reader.ReadLongWord;
    Notice := Reader.ReadBytes;
  finally
    Reader.Free;
  end;
end;

function EncodeOriginData(const Kind, Origin: string; const Data: TBytes): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Kind);
    Writer.WriteString(Origin);
    Writer.WriteBytes(Data);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeOriginData(const Payload: TBytes; out Kind, Origin: string; out Data: TBytes);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Kind := Reader.ReadString;
    Origin := Reader.ReadString;
    Data := Reader.ReadBytes;
  finally
    Reader.Free;
  end;
end;

function EncodeOriginDataRecord(const Data: TBytes): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBytes(Data);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeOriginDataRecord(const Payload: TBytes): TBytes;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result := Reader.ReadBytes;
  finally
    Reader.Free;
  end;
end;

end.
