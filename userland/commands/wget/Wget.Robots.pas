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
  robots.txt (RFC 9309), which wget respects when it recurses:

    User-agent: wget
    Disallow: /private/
    Allow: /private/open.html

    User-agent: *
    Disallow: /cgi-bin/

  The groups whose User-agent names wget (the product token compared
  without case, "wget" in "Wget/1.21") apply; if none does, the "*"
  groups; if there are none either, everything is allowed. Of the rules
  that match a path the longest wins, and Allow wins a tie. A rule's
  "*" matches any characters and a final "$" the end of the path; an
  empty Disallow allows everything. Comments start with "#".

  Plain Pascal (the RTL only), checked on the host by tools/WgetTest.
}
unit Wget.Robots;

{$mode objfpc}
{$H+}

interface

type
  TRobotRule = record
    Allow: Boolean;
    Pattern: string;
  end;

  TRobotRules = array of TRobotRule;

{ The rules of the text that apply to the agent (its product token,
  "wget"). }
function ParseRobots(const Text, AgentToken: string): TRobotRules;
{ True if the path (query included) may be fetched. }
function RobotsAllow(const Rules: TRobotRules; const Path: string): Boolean;
{ RFC 9309's matching: "*" any characters, a final "$" the end. }
function RobotPatternMatches(const Pattern, Path: string): Boolean;

implementation

uses
  SysUtils;

type
  TRobotGroup = record
    Agents: array of string;
    Rules: TRobotRules;
  end;

function StripComment(const Line: string): string;
var
  Hash: Integer;
begin
  Result := Line;
  Hash := Pos('#', Result);
  if Hash > 0 then
    SetLength(Result, Hash - 1);
  Result := Trim(Result);
end;

function GroupNamesAgent(constref Group: TRobotGroup; const AgentToken: string): Boolean;
var
  Agent, Product: string;
  Slash: Integer;
begin
  for Agent in Group.Agents do
  begin
    Product := Agent;
    Slash := Pos('/', Product);
    if Slash > 0 then
      SetLength(Product, Slash - 1);
    if (Product <> '*') and SameText(Trim(Product), AgentToken) then
      Exit(True);
  end;
  Result := False;
end;

function GroupIsForEveryone(constref Group: TRobotGroup): Boolean;
var
  Agent: string;
begin
  for Agent in Group.Agents do
    if Agent = '*' then
      Exit(True);
  Result := False;
end;

procedure AppendRules(var Rules: TRobotRules; const More: TRobotRules);
var
  Rule: TRobotRule;
begin
  for Rule in More do
  begin
    SetLength(Rules, Length(Rules) + 1);
    Rules[High(Rules)] := Rule;
  end;
end;

function ParseRobots(const Text, AgentToken: string): TRobotRules;
var
  Groups: array of TRobotGroup;
  Line, Field, Value: string;
  Colon: Integer;
  LastWasAgent: Boolean;
  Rule: TRobotRule;
  Group: TRobotGroup;
  Named: Boolean;
begin
  Result := nil;
  Groups := nil;
  LastWasAgent := False;
  for Line in StringReplace(Text, #13, '', [rfReplaceAll]).Split([#10]) do
  begin
    Colon := Pos(':', StripComment(Line));
    if Colon = 0 then
      Continue;
    Field := LowerCase(Trim(Copy(StripComment(Line), 1, Colon - 1)));
    Value := Trim(Copy(StripComment(Line), Colon + 1, MaxInt));
    if Field = 'user-agent' then
    begin
      { Agent lines one after another make one group. }
      if not LastWasAgent or (Length(Groups) = 0) then
      begin
        SetLength(Groups, Length(Groups) + 1);
        Groups[High(Groups)] := Default(TRobotGroup);
      end;
      SetLength(Groups[High(Groups)].Agents, Length(Groups[High(Groups)].Agents) + 1);
      Groups[High(Groups)].Agents[High(Groups[High(Groups)].Agents)] := Value;
      LastWasAgent := True;
      Continue;
    end;
    LastWasAgent := False;
    if ((Field <> 'allow') and (Field <> 'disallow')) or (Length(Groups) = 0) then
      Continue;
    { An empty Disallow allows everything: no rule. }
    if Value = '' then
      Continue;
    Rule.Allow := Field = 'allow';
    Rule.Pattern := Value;
    SetLength(Groups[High(Groups)].Rules, Length(Groups[High(Groups)].Rules) + 1);
    Groups[High(Groups)].Rules[High(Groups[High(Groups)].Rules)] := Rule;
  end;
  Named := False;
  for Group in Groups do
    if GroupNamesAgent(Group, AgentToken) then
    begin
      AppendRules(Result, Group.Rules);
      Named := True;
    end;
  if Named then
    Exit;
  for Group in Groups do
    if GroupIsForEveryone(Group) then
      AppendRules(Result, Group.Rules);
end;

function MatchFrom(const Pattern: string; PatternIndex: Integer; const Path: string; PathIndex: Integer): Boolean;
begin
  while PatternIndex <= Length(Pattern) do
  begin
    if Pattern[PatternIndex] = '*' then
    begin
      { Any run, including none. }
      while PathIndex <= Length(Path) + 1 do
      begin
        if MatchFrom(Pattern, PatternIndex + 1, Path, PathIndex) then
          Exit(True);
        Inc(PathIndex);
      end;
      Exit(False);
    end;
    if (Pattern[PatternIndex] = '$') and (PatternIndex = Length(Pattern)) then
      Exit(PathIndex > Length(Path));
    if (PathIndex > Length(Path)) or (Pattern[PatternIndex] <> Path[PathIndex]) then
      Exit(False);
    Inc(PatternIndex);
    Inc(PathIndex);
  end;
  { The pattern is a prefix of the path. }
  Result := True;
end;

function RobotPatternMatches(const Pattern, Path: string): Boolean;
begin
  Result := MatchFrom(Pattern, 1, Path, 1);
end;

function RobotsAllow(const Rules: TRobotRules; const Path: string): Boolean;
var
  Rule: TRobotRule;
  BestLength: Integer;
begin
  Result := True;
  BestLength := -1;
  for Rule in Rules do
    if RobotPatternMatches(Rule.Pattern, Path) then
      if (Length(Rule.Pattern) > BestLength) or ((Length(Rule.Pattern) = BestLength) and Rule.Allow) then
      begin
        BestLength := Length(Rule.Pattern);
        Result := Rule.Allow;
      end;
end;

end.
