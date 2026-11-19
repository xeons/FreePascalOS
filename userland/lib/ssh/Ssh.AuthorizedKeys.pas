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
  The lines of an authorized_keys file with their options (sshd(8),
  "AUTHORIZED_KEYS FILE FORMAT"):

    [options] keytype base64-key [comment]

  options are comma separated, names in any case, values in double
  quotes (\" for a quote inside):

    command="cmd"          what runs instead of what the client asks
    from="pattern-list"    the client's address must match (CIDR too)
    environment="N=V"      set for the session (PermitUserEnvironment)
    expiry-time="YYYYMMDD[HHMM[SS]]"   not taken after this (UTC; a Z
                           at the end is allowed)
    permitopen="host:port" where -L may connect (several; port *)
    permitlisten="[host:]port"         where -R may listen (several)
    principals="list"      with cert-authority: names a certificate
                           must list
    cert-authority         the key signs certificates rather than logs in
    no-pty, no-port-forwarding, no-agent-forwarding,
    no-X11-forwarding, no-user-rc      take that away
    restrict               all of them; pty, port-forwarding,
                           agent-forwarding, X11-forwarding, user-rc
                           give one back
    no-touch-required, verify-required, tunnel="n"
                           accepted, with nothing to do here

  An unknown option or a malformed value refuses the line, as OpenSSH
  does.
}
unit Ssh.AuthorizedKeys;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSshKeyOptions = record
    Command: string;
    FromPatterns: string;
    Environment: TStringArray;
    { Unix time; 0 when there is none. }
    ExpiryTime: Int64;
    PermitOpen: TStringArray;
    PermitListen: TStringArray;
    Principals: string;
    CertAuthority: Boolean;
    NoPty: Boolean;
    NoPortForwarding: Boolean;
    NoAgentForwarding: Boolean;
    NoX11Forwarding: Boolean;
    NoUserRc: Boolean;
  end;

  TSshAuthorizedKey = record
    Blob: string;
    Comment: string;
    Options: TSshKeyOptions;
  end;

{ The options before a key; Problem says what is wrong when False. }
function ParseKeyOptions(const Text: string; out Options: TSshKeyOptions; out Problem: string): Boolean;
{ A line of authorized_keys. False for blank lines and comments (with
  Problem empty) and for bad lines (with Problem set). }
function ParseAuthorizedKeysLine(const Line: string; out Key: TSshAuthorizedKey; out Problem: string): Boolean;
{ Unix time of YYYYMMDD[HHMM[SS]][Z]. }
function ParseExpiryTime(const Text: string; out Time: Int64): Boolean;
{ Days since 1970-01-01 of a date of the proleptic Gregorian calendar. }
function DaysFromCivil(Year, Month, Day: Integer): Int64;
{ Whether host:port is allowed by permitopen entries (host as written,
  port or *). }
function PermitOpenAllows(const Entries: TStringArray; const Host: string; Port: LongWord): Boolean;
{ Whether [host:]port is allowed by permitlisten entries. }
function PermitListenAllows(const Entries: TStringArray; const Host: string; Port: LongWord): Boolean;

implementation

uses
  Ssh.Base64,
  Ssh.Constants,
  Ssh.Wire,
  Ssh.PublicKeys,
  Ssh.Certificates;

procedure Append(var Texts: TStringArray; const Text: string);
begin
  SetLength(Texts, Length(Texts) + 1);
  Texts[High(Texts)] := Text;
end;

function DaysFromCivil(Year, Month, Day: Integer): Int64;
var
  Era, YearOfEra, DayOfYear, DayOfEra: Int64;
  ShiftedMonth: Integer;
begin
  if Month <= 2 then
    Dec(Year);
  if Year >= 0 then
    Era := Year div 400
  else
    Era := (Year - 399) div 400;
  YearOfEra := Year - Era * 400;
  if Month > 2 then
    ShiftedMonth := Month - 3
  else
    ShiftedMonth := Month + 9;
  DayOfYear := (153 * ShiftedMonth + 2) div 5 + Day - 1;
  DayOfEra := YearOfEra * 365 + YearOfEra div 4 - YearOfEra div 100 + DayOfYear;
  Result := Era * 146097 + DayOfEra - 719468;
end;

function ParseExpiryTime(const Text: string; out Time: Int64): Boolean;
var
  Digits: string;
  Year, Month, Day, Hour, Minute, Second, Index: Integer;
begin
  Time := 0;
  Digits := Text;
  if (Digits <> '') and (UpCase(Digits[Length(Digits)]) = 'Z') then
    Delete(Digits, Length(Digits), 1);
  if not (Length(Digits) in [8, 12, 14]) then
    Exit(False);
  for Index := 1 to Length(Digits) do
    if not (Digits[Index] in ['0'..'9']) then
      Exit(False);
  Year := StrToInt(Copy(Digits, 1, 4));
  Month := StrToInt(Copy(Digits, 5, 2));
  Day := StrToInt(Copy(Digits, 7, 2));
  Hour := 0;
  Minute := 0;
  Second := 0;
  if Length(Digits) >= 12 then
  begin
    Hour := StrToInt(Copy(Digits, 9, 2));
    Minute := StrToInt(Copy(Digits, 11, 2));
  end;
  if Length(Digits) = 14 then
    Second := StrToInt(Copy(Digits, 13, 2));
  if (Month < 1) or (Month > 12) or (Day < 1) or (Day > 31) or (Hour > 23) or (Minute > 59) or (Second > 60) then
    Exit(False);
  Time := DaysFromCivil(Year, Month, Day) * 86400 + Hour * 3600 + Minute * 60 + Second;
  Result := True;
end;

{ The next option at Position: its name and, after =, its quoted value. }
function NextOption(const Text: string; var Position: Integer; out Name, Value: string; out HasValue: Boolean;
  out Problem: string): Boolean;
var
  Start: Integer;
begin
  Name := '';
  Value := '';
  HasValue := False;
  Problem := '';
  Start := Position;
  while (Position <= Length(Text)) and not (Text[Position] in [',', '=']) do
    Inc(Position);
  Name := LowerCase(Copy(Text, Start, Position - Start));
  if Name = '' then
  begin
    Problem := 'empty option';
    Exit(False);
  end;
  if (Position <= Length(Text)) and (Text[Position] = '=') then
  begin
    HasValue := True;
    Inc(Position);
    if (Position > Length(Text)) or (Text[Position] <> '"') then
    begin
      Problem := 'the value of ' + Name + ' is not in double quotes';
      Exit(False);
    end;
    Inc(Position);
    while (Position <= Length(Text)) and (Text[Position] <> '"') do
    begin
      if (Text[Position] = '\') and (Position < Length(Text)) and (Text[Position + 1] = '"') then
        Inc(Position);
      Value := Value + Text[Position];
      Inc(Position);
    end;
    if Position > Length(Text) then
    begin
      Problem := 'the value of ' + Name + ' has no closing quote';
      Exit(False);
    end;
    Inc(Position);
  end;
  if Position <= Length(Text) then
  begin
    if Text[Position] <> ',' then
    begin
      Problem := 'junk after option ' + Name;
      Exit(False);
    end;
    Inc(Position);
    if Position > Length(Text) then
    begin
      Problem := 'a comma at the end of the options';
      Exit(False);
    end;
  end;
  Result := True;
end;

function ApplyFlag(const Name: string; var Options: TSshKeyOptions): Boolean;
begin
  Result := True;
  if Name = 'restrict' then
  begin
    Options.NoPty := True;
    Options.NoPortForwarding := True;
    Options.NoAgentForwarding := True;
    Options.NoX11Forwarding := True;
    Options.NoUserRc := True;
  end
  else if Name = 'no-pty' then
    Options.NoPty := True
  else if Name = 'pty' then
    Options.NoPty := False
  else if Name = 'no-port-forwarding' then
    Options.NoPortForwarding := True
  else if Name = 'port-forwarding' then
    Options.NoPortForwarding := False
  else if Name = 'no-agent-forwarding' then
    Options.NoAgentForwarding := True
  else if Name = 'agent-forwarding' then
    Options.NoAgentForwarding := False
  else if Name = 'no-x11-forwarding' then
    Options.NoX11Forwarding := True
  else if Name = 'x11-forwarding' then
    Options.NoX11Forwarding := False
  else if Name = 'no-user-rc' then
    Options.NoUserRc := True
  else if Name = 'user-rc' then
    Options.NoUserRc := False
  else if Name = 'cert-authority' then
    Options.CertAuthority := True
  else if (Name = 'no-touch-required') or (Name = 'verify-required') then
  else
    Result := False;
end;

function ValidPermitOpen(const Value: string): Boolean;
var
  Colon: Integer;
  Port: Integer;
  PortText: string;
begin
  Colon := LastDelimiter(':', Value);
  if Colon <= 1 then
    Exit(False);
  PortText := Copy(Value, Colon + 1, MaxInt);
  Result := (PortText = '*') or (TryStrToInt(PortText, Port) and (Port >= 1) and (Port <= 65535));
end;

function ValidPermitListen(const Value: string): Boolean;
var
  Colon: Integer;
  Port: Integer;
  PortText: string;
begin
  Colon := LastDelimiter(':', Value);
  PortText := Copy(Value, Colon + 1, MaxInt);
  Result := (PortText = '*') or (TryStrToInt(PortText, Port) and (Port >= 0) and (Port <= 65535));
end;

function ApplyValue(const Name, Value: string; var Options: TSshKeyOptions; out Problem: string): Boolean;
begin
  Problem := '';
  Result := True;
  if Name = 'command' then
    Options.Command := Value
  else if Name = 'from' then
    Options.FromPatterns := Value
  else if Name = 'environment' then
  begin
    if (Pos('=', Value) <= 1) or (Pos(' ', Copy(Value, 1, Pos('=', Value))) > 0) then
    begin
      Problem := 'environment is not NAME=value';
      Exit(False);
    end;
    Append(Options.Environment, Value);
  end
  else if Name = 'expiry-time' then
  begin
    if not ParseExpiryTime(Value, Options.ExpiryTime) then
    begin
      Problem := 'bad expiry-time ' + Value;
      Exit(False);
    end;
  end
  else if Name = 'permitopen' then
  begin
    if not ValidPermitOpen(Value) then
    begin
      Problem := 'bad permitopen ' + Value;
      Exit(False);
    end;
    Append(Options.PermitOpen, Value);
  end
  else if Name = 'permitlisten' then
  begin
    if not ValidPermitListen(Value) then
    begin
      Problem := 'bad permitlisten ' + Value;
      Exit(False);
    end;
    Append(Options.PermitListen, Value);
  end
  else if Name = 'principals' then
    Options.Principals := Value
  else if Name = 'tunnel' then
  else
  begin
    Problem := 'unknown option ' + Name;
    Result := False;
  end;
end;

function ParseKeyOptions(const Text: string; out Options: TSshKeyOptions; out Problem: string): Boolean;
var
  Position: Integer;
  Name, Value: string;
  HasValue: Boolean;
begin
  Options := Default(TSshKeyOptions);
  Problem := '';
  Position := 1;
  while Position <= Length(Text) do
  begin
    if not NextOption(Text, Position, Name, Value, HasValue, Problem) then
      Exit(False);
    if HasValue then
    begin
      if not ApplyValue(Name, Value, Options, Problem) then
        Exit(False);
    end
    else if not ApplyFlag(Name, Options) then
    begin
      Problem := 'unknown option ' + Name;
      Exit(False);
    end;
  end;
  Result := True;
end;

function IsKeyTypeName(const Name: string): Boolean;
begin
  Result := (Name = HostKeyEd25519) or (Name = HostKeyEcdsaP256) or (Name = PublicKeyRsa) or
    IsCertificateKeyType(Name);
end;

{ The options field: up to the first blank outside double quotes. }
function OptionsField(const Line: string; var Position: Integer): string;
var
  Start: Integer;
  Quoted: Boolean;
begin
  Start := Position;
  Quoted := False;
  while Position <= Length(Line) do
  begin
    if (Line[Position] = '\') and Quoted and (Position < Length(Line)) then
      Inc(Position)
    else if Line[Position] = '"' then
      Quoted := not Quoted
    else if (Line[Position] in [' ', #9]) and not Quoted then
      Break;
    Inc(Position);
  end;
  Result := Copy(Line, Start, Position - Start);
end;

function NextWord(const Line: string; var Position: Integer): string;
var
  Start: Integer;
begin
  while (Position <= Length(Line)) and (Line[Position] in [' ', #9]) do
    Inc(Position);
  Start := Position;
  while (Position <= Length(Line)) and not (Line[Position] in [' ', #9]) do
    Inc(Position);
  Result := Copy(Line, Start, Position - Start);
end;

function ParseAuthorizedKeysLine(const Line: string; out Key: TSshAuthorizedKey; out Problem: string): Boolean;
var
  Position: Integer;
  First, KeyType, Encoded, OptionsText: string;
  Parsed: TSshPublicKey;
  Certificate: TSshCertificate;
begin
  Key := Default(TSshAuthorizedKey);
  Problem := '';
  Result := False;
  Position := 1;
  while (Position <= Length(Line)) and (Line[Position] in [' ', #9]) do
    Inc(Position);
  if (Position > Length(Line)) or (Line[Position] = '#') or (Line[Position] in [#13, #10]) then
    Exit;
  OptionsText := '';
  First := NextWord(Line, Position);
  if IsKeyTypeName(First) then
    KeyType := First
  else
  begin
    Position := Position - Length(First);
    OptionsText := OptionsField(Line, Position);
    if not ParseKeyOptions(OptionsText, Key.Options, Problem) then
      Exit;
    KeyType := NextWord(Line, Position);
    if not IsKeyTypeName(KeyType) then
    begin
      Problem := 'unknown key type ' + KeyType;
      Exit;
    end;
  end;
  Encoded := NextWord(Line, Position);
  if not DecodeBase64(Encoded, Key.Blob) then
  begin
    Problem := 'the key is not base64';
    Exit;
  end;
  if IsCertificateKeyType(KeyType) then
  begin
    if not ParseCertificate(Key.Blob, Certificate) then
    begin
      Problem := 'malformed certificate';
      Exit;
    end;
  end
  else if not ParsePublicKeyBlob(Key.Blob, Parsed) then
  begin
    Problem := 'malformed key';
    Exit;
  end;
  if Copy(Key.Blob, 5, Length(KeyType)) <> KeyType then
  begin
    Problem := 'the key is not of the type written';
    Exit;
  end;
  Key.Comment := Trim(Copy(Line, Position, MaxInt));
  Result := True;
end;

{ host:port of an entry, the host without brackets. }
procedure SplitEntry(const Entry: string; out Host, Port: string);
var
  Colon: Integer;
begin
  Colon := LastDelimiter(':', Entry);
  if Colon = 0 then
  begin
    Host := '';
    Port := Entry;
    Exit;
  end;
  Host := Copy(Entry, 1, Colon - 1);
  Port := Copy(Entry, Colon + 1, MaxInt);
  if (Host <> '') and (Host[1] = '[') and (Host[Length(Host)] = ']') then
    Host := Copy(Host, 2, Length(Host) - 2);
end;

function PermitOpenAllows(const Entries: TStringArray; const Host: string; Port: LongWord): Boolean;
var
  Index: Integer;
  EntryHost, EntryPort: string;
begin
  for Index := 0 to High(Entries) do
  begin
    SplitEntry(Entries[Index], EntryHost, EntryPort);
    if ((EntryHost = '*') or SameText(EntryHost, Host)) and ((EntryPort = '*') or (EntryPort = IntToStr(Port))) then
      Exit(True);
  end;
  Result := False;
end;

function PermitListenAllows(const Entries: TStringArray; const Host: string; Port: LongWord): Boolean;
var
  Index: Integer;
  EntryHost, EntryPort: string;
begin
  for Index := 0 to High(Entries) do
  begin
    SplitEntry(Entries[Index], EntryHost, EntryPort);
    if ((EntryHost = '') or (EntryHost = '*') or SameText(EntryHost, Host)) and
      ((EntryPort = '*') or (EntryPort = IntToStr(Port))) then
      Exit(True);
  end;
  Result := False;
end;

end.
