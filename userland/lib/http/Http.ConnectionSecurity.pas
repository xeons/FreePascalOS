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
  What the process's last TLS connection to each host and port was: the
  protocol version, the cipher suite and the server's certificates as
  text. The socket transport records every handshake that succeeded
  (Http.SocketTransports); a browser shows it in its site identity and
  page information. Thread safe; the newest 256 hosts are kept.
}
unit Http.ConnectionSecurity;

{$mode objfpc}
{$H+}

interface

uses
  Tls.CertificateSummaries;

type
  THttpConnectionSecurity = record
    Secure: Boolean;
    { 'TLS 1.3', 'TLS 1.2'. }
    Protocol: string;
    Cipher: string;
    Host: string;
    Port: Word;
    { The server's certificate first, then the chain it sent, then the
      root that signed the last when it was not sent. }
    Chain: TTlsCertificateSummaryList;
  end;

procedure RecordConnectionSecurity(constref Info: THttpConnectionSecurity);
function FindConnectionSecurity(const Host: string; Port: Word; out Info: THttpConnectionSecurity): Boolean;
procedure ClearConnectionSecurity;

implementation

uses
  SysUtils;

const
  MaximumRecords = 256;

var
  RecordsLock: TRTLCriticalSection;
  { The oldest first. }
  Records: array of THttpConnectionSecurity;

function IndexOfRecord(const Host: string; Port: Word): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Records) do
    if (Records[Index].Port = Port) and (Records[Index].Host = Host) then
      Exit(Index);
  Result := -1;
end;

procedure RecordConnectionSecurity(constref Info: THttpConnectionSecurity);
var
  Entry: THttpConnectionSecurity;
  Existing: Integer;
begin
  Entry := Info;
  Entry.Host := LowerCase(Info.Host);
  Entry.Chain := Copy(Info.Chain, 0, Length(Info.Chain));
  EnterCriticalSection(RecordsLock);
  try
    Existing := IndexOfRecord(Entry.Host, Entry.Port);
    if Existing >= 0 then
      Delete(Records, Existing, 1);
    while Length(Records) >= MaximumRecords do
      Delete(Records, 0, 1);
    SetLength(Records, Length(Records) + 1);
    Records[High(Records)] := Entry;
  finally
    LeaveCriticalSection(RecordsLock);
  end;
end;

function FindConnectionSecurity(const Host: string; Port: Word; out Info: THttpConnectionSecurity): Boolean;
var
  Index: Integer;
begin
  Info := Default(THttpConnectionSecurity);
  EnterCriticalSection(RecordsLock);
  try
    Index := IndexOfRecord(LowerCase(Host), Port);
    Result := Index >= 0;
    if Result then
    begin
      Info := Records[Index];
      Info.Chain := Copy(Records[Index].Chain, 0, Length(Records[Index].Chain));
    end;
  finally
    LeaveCriticalSection(RecordsLock);
  end;
end;

procedure ClearConnectionSecurity;
begin
  EnterCriticalSection(RecordsLock);
  try
    Records := nil;
  finally
    LeaveCriticalSection(RecordsLock);
  end;
end;

initialization
  InitCriticalSection(RecordsLock);

finalization
  Records := nil;
  DoneCriticalSection(RecordsLock);

end.
