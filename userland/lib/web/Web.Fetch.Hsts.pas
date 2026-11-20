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
  HTTP Strict Transport Security (RFC 6797), the known hosts of a
  browser profile:

  - Strict-Transport-Security is taken only from a response that came
    over https from a host that is a domain name (not an address); the
    field needs max-age (delta-seconds) and may have includeSubDomains;
    a directive given twice makes the whole field ignored, unknown
    directives are skipped; max-age=0 forgets the host.
  - A URL is upgraded (http to https, ws to wss, port 80 to 443) when
    its host is known (congruent match) or a superdomain is known with
    includeSubDomains, until the entry expires.
  - Entries are kept per host (lower case) with their expiry in Unix
    seconds; SaveToText and LoadFromText keep them in a file, one line
    per host. The store locks itself: pages on several threads share it.
}
unit Web.Fetch.Hsts;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes,
  Url.Records;

type
  THstsPolicy = record
    Valid: Boolean;
    MaxAge: Int64;
    IncludeSubDomains: Boolean;
  end;

  THstsEntry = class
  public
    Expiry: Int64;
    IncludeSubDomains: Boolean;
  end;

  THstsClock = function: Int64;

  THstsStore = class
  private
    FLock: TRTLCriticalSection;
    { Host names, sorted, each with its THstsEntry (owned). }
    FEntries: TStringList;
    FClock: THstsClock;
    function EntryOf(const Host: string): THstsEntry;
    procedure SetEntry(const Host: string; Expiry: Int64; IncludeSubDomains: Boolean);
    procedure RemoveEntry(const Host: string);
    function Now: Int64;
    function FindLocked(const Host: string; out Entry: THstsEntry): Boolean;
  public
    constructor Create(Clock: THstsClock = nil);
    destructor Destroy; override;
    { The field of a response for Url (ignored unless https and a domain). }
    procedure ProcessResponseField(constref Url: TUrlRecord; const FieldValue: string);
    procedure AddHost(const Host: string; MaxAgeSeconds: Int64; IncludeSubDomains: Boolean);
    procedure RemoveHost(const Host: string);
    { The host or a superdomain with includeSubDomains is known. }
    function IsKnownHost(const Host: string): Boolean;
    { Url upgraded when it should be; True if it was changed. }
    function UpgradeUrl(var Url: TUrlRecord): Boolean;
    function SaveToText: string;
    procedure LoadFromText(const Text: string);
    function Count: Integer;
  end;

function ParseStrictTransportSecurity(const Value: string): THstsPolicy;

implementation

uses
  Web.Fetch.MimeTypes;

function SystemUnixTime: Int64;
begin
  Result := Round((SysUtils.Now - 25569) * 86400);
end;

function UnquoteDirectiveValue(const Value: string): string;
var
  Index: Integer;
begin
  if (Length(Value) < 2) or (Value[1] <> '"') or (Value[Length(Value)] <> '"') then
    Exit(Value);
  Result := '';
  Index := 2;
  while Index < Length(Value) do
  begin
    if (Value[Index] = '\') and (Index + 1 < Length(Value)) then
      Inc(Index);
    Result := Result + Value[Index];
    Inc(Index);
  end;
end;

function ParseStrictTransportSecurity(const Value: string): THstsPolicy;
var
  Directives: TStringArray;
  Index, Equals, Position: Integer;
  Directive, Name, DirectiveValue: string;
  SeenMaxAge, SeenInclude: Boolean;
  Number: Int64;
begin
  Result := Default(THstsPolicy);
  SeenMaxAge := False;
  SeenInclude := False;
  Directives := Value.Split([';']);
  for Index := 0 to High(Directives) do
  begin
    Directive := TrimHttpWhitespace(Directives[Index]);
    if Directive = '' then
      Continue;
    Equals := Pos('=', Directive);
    if Equals > 0 then
    begin
      Name := LowerCase(TrimHttpWhitespace(Copy(Directive, 1, Equals - 1)));
      DirectiveValue := UnquoteDirectiveValue(TrimHttpWhitespace(Copy(Directive, Equals + 1, MaxInt)));
    end
    else
    begin
      Name := LowerCase(Directive);
      DirectiveValue := '';
    end;
    if Name = 'max-age' then
    begin
      if SeenMaxAge or (DirectiveValue = '') then
        Exit(Default(THstsPolicy));
      Number := 0;
      for Position := 1 to Length(DirectiveValue) do
      begin
        if not (DirectiveValue[Position] in ['0'..'9']) then
          Exit(Default(THstsPolicy));
        if Number < High(Int64) div 20 then
          Number := Number * 10 + Ord(DirectiveValue[Position]) - Ord('0');
      end;
      Result.MaxAge := Number;
      SeenMaxAge := True;
    end
    else if Name = 'includesubdomains' then
    begin
      if SeenInclude then
        Exit(Default(THstsPolicy));
      Result.IncludeSubDomains := True;
      SeenInclude := True;
    end;
  end;
  Result.Valid := SeenMaxAge;
end;

constructor THstsStore.Create(Clock: THstsClock);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FEntries := TStringList.Create;
  FEntries.Sorted := True;
  FEntries.CaseSensitive := True;
  FEntries.OwnsObjects := True;
  FClock := Clock;
end;

destructor THstsStore.Destroy;
begin
  FEntries.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function THstsStore.Now: Int64;
begin
  if Assigned(FClock) then
    Result := FClock()
  else
    Result := SystemUnixTime;
end;

function THstsStore.EntryOf(const Host: string): THstsEntry;
var
  Index: Integer;
begin
  if FEntries.Find(Host, Index) then
    Result := THstsEntry(FEntries.Objects[Index])
  else
    Result := nil;
end;

procedure THstsStore.SetEntry(const Host: string; Expiry: Int64; IncludeSubDomains: Boolean);
var
  Entry: THstsEntry;
begin
  Entry := EntryOf(Host);
  if Entry = nil then
  begin
    Entry := THstsEntry.Create;
    FEntries.AddObject(Host, Entry);
  end;
  Entry.Expiry := Expiry;
  Entry.IncludeSubDomains := IncludeSubDomains;
end;

procedure THstsStore.RemoveEntry(const Host: string);
var
  Index: Integer;
begin
  if FEntries.Find(Host, Index) then
    FEntries.Delete(Index);
end;

procedure THstsStore.AddHost(const Host: string; MaxAgeSeconds: Int64; IncludeSubDomains: Boolean);
begin
  EnterCriticalSection(FLock);
  try
    if MaxAgeSeconds <= 0 then
      RemoveEntry(LowerCase(Host))
    else
      SetEntry(LowerCase(Host), Now + MaxAgeSeconds, IncludeSubDomains);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THstsStore.RemoveHost(const Host: string);
begin
  EnterCriticalSection(FLock);
  try
    RemoveEntry(LowerCase(Host));
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THstsStore.ProcessResponseField(constref Url: TUrlRecord; const FieldValue: string);
var
  Policy: THstsPolicy;
begin
  if (Url.Scheme <> 'https') or (Url.Host.Kind <> UrlHostDomain) then
    Exit;
  Policy := ParseStrictTransportSecurity(FieldValue);
  if not Policy.Valid then
    Exit;
  AddHost(Url.Host.Name, Policy.MaxAge, Policy.IncludeSubDomains);
end;

function THstsStore.FindLocked(const Host: string; out Entry: THstsEntry): Boolean;
var
  Candidate: string;
  Dot: Integer;
  Congruent: Boolean;
  Moment: Int64;
begin
  Moment := Now;
  Candidate := LowerCase(Host);
  Congruent := True;
  while Candidate <> '' do
  begin
    Entry := EntryOf(Candidate);
    if Entry <> nil then
    begin
      if Entry.Expiry <= Moment then
        RemoveEntry(Candidate)
      else if Congruent or Entry.IncludeSubDomains then
        Exit(True);
    end;
    Dot := Pos('.', Candidate);
    if Dot = 0 then
      Break;
    Candidate := Copy(Candidate, Dot + 1, MaxInt);
    Congruent := False;
  end;
  Entry := nil;
  Result := False;
end;

function THstsStore.IsKnownHost(const Host: string): Boolean;
var
  Entry: THstsEntry;
begin
  EnterCriticalSection(FLock);
  try
    Result := FindLocked(Host, Entry);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THstsStore.UpgradeUrl(var Url: TUrlRecord): Boolean;
begin
  Result := False;
  if ((Url.Scheme <> 'http') and (Url.Scheme <> 'ws')) or (Url.Host.Kind <> UrlHostDomain) then
    Exit;
  if not IsKnownHost(Url.Host.Name) then
    Exit;
  if Url.Scheme = 'http' then
    Url.Scheme := 'https'
  else
    Url.Scheme := 'wss';
  if Url.Port = 443 then
    Url.Port := UrlPortNull
  else if Url.Port = 80 then
    Url.Port := UrlPortNull;
  Result := True;
end;

function THstsStore.SaveToText: string;
var
  Index: Integer;
  Entry: THstsEntry;
  Moment: Int64;
begin
  Result := '';
  Moment := Now;
  EnterCriticalSection(FLock);
  try
    for Index := 0 to FEntries.Count - 1 do
    begin
      Entry := THstsEntry(FEntries.Objects[Index]);
      if Entry.Expiry > Moment then
        Result := Result + FEntries[Index] + ' ' + IntToStr(Entry.Expiry) + ' ' +
          BoolToStr(Entry.IncludeSubDomains, '1', '0') + LineEnding;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure THstsStore.LoadFromText(const Text: string);
var
  Lines, Parts: TStringArray;
  Index: Integer;
  Expiry: Int64;
begin
  Lines := Text.Split([#10]);
  EnterCriticalSection(FLock);
  try
    for Index := 0 to High(Lines) do
    begin
      Parts := Trim(Lines[Index]).Split([' ']);
      if (Length(Parts) <> 3) or not TryStrToInt64(Parts[1], Expiry) then
        Continue;
      SetEntry(LowerCase(Parts[0]), Expiry, Parts[2] = '1');
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function THstsStore.Count: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FEntries.Count;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

end.
