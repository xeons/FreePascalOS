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
  Public suffixes and sites (the Public Suffix List's algorithm, as the
  URL Standard's "public suffix" and "registrable domain" use it):
  rules are labels ("co.uk"), wildcards ("*.ck") and exceptions
  ("!www.ck"); the longest matching rule wins, an exception over the
  others, and with no match the rule is "*" (every top-level domain is
  a public suffix). The registrable domain is the public suffix and one
  label more; two hosts are the same site when their registrable
  domains are the same (IP addresses only when equal).

  The list compiled in holds the second-level suffixes of the largest
  country domains and the hosting suffixes most often met; the full
  list is used instead when /usr/share/publicsuffix/public_suffix_list.dat
  (or a file a program names) is there. Thread safe: the rules are
  loaded once, under a lock.

  Plain Pascal (the RTL and Classes), checked on the host by
  tools/HttpTest.
}
unit Http.PublicSuffixes;

{$mode objfpc}
{$H+}

interface

const
  SystemPublicSuffixFile = '/usr/share/publicsuffix/public_suffix_list.dat';

{ The public suffix of a lower case ASCII domain ("example.co.uk" ->
  "co.uk"). }
function PublicSuffixOf(const Domain: string): string;
function IsPublicSuffix(const Domain: string): Boolean;
{ The suffix and one label more, or '' when Domain is a public suffix
  itself (or an IP address, for which there is none). }
function RegistrableDomainOf(const Domain: string): string;
{ Same site (HTML's "same site" without schemes): the same registrable
  domain, or the same host when there is none. }
function HostsAreSameSite(const First, Second: string): Boolean;
{ Uses the rules of a Public Suffix List file instead of the compiled
  ones; False if it cannot be read. }
function LoadPublicSuffixFile(const FileName: string): Boolean;

implementation

uses
  Classes,
  SysUtils,
  StrUtils;

const
  BuiltInRules: array[0..140] of string = (
    'ac.uk', 'co.uk', 'gov.uk', 'ltd.uk', 'me.uk', 'net.uk', 'nhs.uk', 'org.uk', 'plc.uk', 'police.uk', 'sch.uk',
    'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au', 'asn.au', 'id.au',
    'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp', 'gr.jp', 'ed.jp', 'lg.jp', 'ad.jp',
    'co.nz', 'net.nz', 'org.nz', 'govt.nz', 'ac.nz', 'school.nz', 'geek.nz',
    'com.br', 'net.br', 'org.br', 'gov.br', 'edu.br', 'art.br', 'blog.br',
    'com.cn', 'net.cn', 'org.cn', 'gov.cn', 'edu.cn', 'ac.cn',
    'co.in', 'net.in', 'org.in', 'gen.in', 'firm.in', 'ind.in', 'gov.in', 'ac.in', 'edu.in',
    'com.mx', 'org.mx', 'gob.mx', 'edu.mx', 'net.mx',
    'co.za', 'org.za', 'gov.za', 'ac.za', 'net.za',
    'com.tr', 'org.tr', 'net.tr', 'gov.tr', 'edu.tr',
    'com.tw', 'org.tw', 'net.tw', 'gov.tw', 'edu.tw',
    'co.kr', 'or.kr', 'ne.kr', 'go.kr', 'ac.kr',
    'com.sg', 'org.sg', 'net.sg', 'gov.sg', 'edu.sg',
    'com.hk', 'org.hk', 'net.hk', 'gov.hk', 'edu.hk',
    'com.ar', 'org.ar', 'net.ar', 'gob.ar',
    'co.il', 'org.il', 'net.il', 'ac.il', 'gov.il',
    'com.ru', 'org.ru', 'net.ru', 'msk.ru', 'spb.ru',
    'com.ua', 'org.ua', 'net.ua', 'kiev.ua',
    'co.id', 'or.id', 'web.id', 'ac.id', 'go.id',
    'com.pl', 'org.pl', 'net.pl', 'gov.pl',
    '*.ck', '!www.ck', '*.bd', '*.np', '*.er', '*.fk', '*.kh', '*.mm', '*.pg',
    'github.io', 'gitlab.io', 'blogspot.com', 'herokuapp.com', 'appspot.com', 'azurewebsites.net',
    'cloudfront.net', 'netlify.app', 'vercel.app', 'pages.dev', 'workers.dev', 'firebaseapp.com', 'web.app',
    's3.amazonaws.com');

var
  Rules: TStringList = nil;
  RulesLock: TRTLCriticalSection;
  RulesLockReady: LongInt = 0;

procedure EnsureLock;
begin
  { The first caller sets the lock up; it is never torn down. }
  if InterLockedCompareExchange(RulesLockReady, 1, 0) = 0 then
  begin
    InitCriticalSection(RulesLock);
    InterLockedExchange(RulesLockReady, 2);
  end;
  while RulesLockReady <> 2 do
    ThreadSwitch;
end;

function NewRuleList: TStringList;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Result.CaseSensitive := True;
end;

procedure AddRule(List: TStringList; const Line: string);
var
  Rule: string;
begin
  Rule := LowerCase(Trim(Line));
  if Pos(' ', Rule) > 0 then
    Rule := Copy(Rule, 1, Pos(' ', Rule) - 1);
  if (Rule = '') or StartsStr('//', Rule) then
    Exit;
  List.Add(Rule);
end;

procedure EnsureRules;
var
  Index: Integer;
  Loaded: TStringList;
begin
  EnsureLock;
  EnterCriticalSection(RulesLock);
  try
    if Rules <> nil then
      Exit;
    Loaded := NewRuleList;
    if FileExists(SystemPublicSuffixFile) then
      try
        with TStringList.Create do
          try
            LoadFromFile(SystemPublicSuffixFile);
            for Index := 0 to Count - 1 do
              AddRule(Loaded, Strings[Index]);
          finally
            Free;
          end;
      except
        Loaded.Clear;
      end;
    if Loaded.Count = 0 then
      for Index := 0 to High(BuiltInRules) do
        AddRule(Loaded, BuiltInRules[Index]);
    Rules := Loaded;
  finally
    LeaveCriticalSection(RulesLock);
  end;
end;

function LoadPublicSuffixFile(const FileName: string): Boolean;
var
  Lines, Loaded: TStringList;
  Index: Integer;
begin
  Result := False;
  Lines := TStringList.Create;
  Loaded := NewRuleList;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      Exit;
    end;
    for Index := 0 to Lines.Count - 1 do
      AddRule(Loaded, Lines[Index]);
    EnsureRules;
    EnterCriticalSection(RulesLock);
    try
      Rules.Free;
      Rules := Loaded;
      Loaded := nil;
    finally
      LeaveCriticalSection(RulesLock);
    end;
    Result := True;
  finally
    Loaded.Free;
    Lines.Free;
  end;
end;

function HasRule(const Rule: string): Boolean;
var
  Index: Integer;
begin
  Result := Rules.Find(Rule, Index);
end;

function IsIpAddressText(const Host: string): Boolean;
var
  Character: Char;
begin
  if (Pos(':', Host) > 0) or (Host = '') then
    Exit(True);
  for Character in Host do
    if not (Character in ['0'..'9', '.']) then
      Exit(False);
  Result := True;
end;

function PublicSuffixOf(const Domain: string): string;
var
  Labels: TStringArray;
  Index, Best: Integer;
  Candidate, Wild: string;
begin
  EnsureRules;
  Labels := Domain.Split(['.']);
  if Length(Labels) = 0 then
    Exit('');
  { With no rule the last label is the suffix ("*"). }
  Best := High(Labels);
  EnterCriticalSection(RulesLock);
  try
    for Index := 0 to High(Labels) do
    begin
      Candidate := String.Join('.', Copy(Labels, Index, MaxInt));
      if HasRule('!' + Candidate) then
      begin
        Best := Index + 1;
        Break;
      end;
      if HasRule(Candidate) and (Index < Best) then
        Best := Index;
      if Index > 0 then
      begin
        Wild := '*.' + Candidate;
        if HasRule(Wild) and (Index - 1 < Best) then
          Best := Index - 1;
      end;
    end;
  finally
    LeaveCriticalSection(RulesLock);
  end;
  if Best > High(Labels) then
    Best := High(Labels);
  Result := String.Join('.', Copy(Labels, Best, MaxInt));
end;

function IsPublicSuffix(const Domain: string): Boolean;
begin
  Result := not IsIpAddressText(Domain) and (PublicSuffixOf(Domain) = Domain);
end;

function RegistrableDomainOf(const Domain: string): string;
var
  Suffix, Rest: string;
  Dot: Integer;
begin
  if IsIpAddressText(Domain) then
    Exit('');
  Suffix := PublicSuffixOf(Domain);
  if (Suffix = Domain) or not EndsStr('.' + Suffix, Domain) then
    Exit('');
  Rest := Copy(Domain, 1, Length(Domain) - Length(Suffix) - 1);
  Dot := RPos('.', Rest);
  Result := Copy(Rest, Dot + 1, MaxInt) + '.' + Suffix;
end;

function HostsAreSameSite(const First, Second: string): Boolean;
var
  FirstSite, SecondSite: string;
begin
  if First = Second then
    Exit(True);
  FirstSite := RegistrableDomainOf(First);
  SecondSite := RegistrableDomainOf(Second);
  Result := (FirstSite <> '') and (FirstSite = SecondSite);
end;

end.
