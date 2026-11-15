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
  Service definitions: what a file in /etc/services says.

  A service is the file NAME.service (NAME: letters, digits, "-" and
  "_"). Each line is "key = value"; blank lines and lines starting with
  "#" are ignored:

    description   = The display server       what it is, for people
    program       = /bin/displayserver       the program (required)
    arguments     = -x "two words"           its arguments
    user          = root                     who it runs as (root)
    needs         = displayserver            services that must be
                                             running (and ready) first
    modes         = graphical text           the boot modes it starts in
                                             (none: only when asked for)
    restart       = on-failure               never, on-failure (the
                                             default) or always
    restart-limit = 3                        restarts in a row before it
                                             is left failed (0: no limit)
    restart-delay = 1                        seconds before a restart
    ready         = notify                   started (the default): ready
                                             once started; notify: once
                                             it says so (NotifyServiceReady)
    ready-timeout = 30                       seconds to wait for that
    console       = yes                      runs on the console (input,
                                             output and the foreground);
                                             no (the default): its output
                                             goes to its log

  Seconds may have a fraction ("0.5"). A line the parser does not know is
  an error that names the line, and the service is never started.
}
unit Services.Definitions;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  ServiceFileSuffix = '.service';
  DefaultRestartLimit = 3;
  DefaultRestartDelayMilliseconds = 1000;
  DefaultReadyTimeoutMilliseconds = 30000;

type
  TRestartPolicy = (RestartNever, RestartOnFailure, RestartAlways);
  TReadiness = (ReadyWhenStarted, ReadyWhenNotified);

  TServiceDefinition = record
    Name: string;
    Description: string;
    ProgramPath: string;
    Arguments: array of string;
    UserName: string;
    Needs: array of string;
    Modes: array of string;
    Restart: TRestartPolicy;
    RestartLimit: LongInt;
    RestartDelayMilliseconds: LongInt;
    Readiness: TReadiness;
    ReadyTimeoutMilliseconds: LongInt;
    OnConsole: Boolean;
  end;

{ A definition with every default and the name Name. }
procedure DefaultDefinition(const Name: string; out Definition: TServiceDefinition);
{ True if Name may name a service. }
function IsServiceName(const Name: string): Boolean;
{ Reads the definition in Lines (a file's lines) into Definition, which
  holds the defaults. False with Problem set ("line 3: ...") when a line
  is wrong or the program is missing. }
function ParseDefinition(Lines: TStringArray; var Definition: TServiceDefinition; out Problem: string): Boolean;
{ Reads the file Path. }
function ReadDefinitionFile(const Path, Name: string; out Definition: TServiceDefinition; out Problem: string): Boolean;

{ True if the definition lists Mode among its boot modes. }
function BelongsToMode(const Definition: TServiceDefinition; const Mode: string): Boolean;

function RestartPolicyName(Policy: TRestartPolicy): string;
function ReadinessName(Readiness: TReadiness): string;

implementation

uses
  Classes;

const
  MaximumNameLength = 47;
  MaximumSeconds = 3600;

procedure DefaultDefinition(const Name: string; out Definition: TServiceDefinition);
begin
  Definition.Name := Name;
  Definition.Description := '';
  Definition.ProgramPath := '';
  Definition.Arguments := nil;
  Definition.UserName := 'root';
  Definition.Needs := nil;
  Definition.Modes := nil;
  Definition.Restart := RestartOnFailure;
  Definition.RestartLimit := DefaultRestartLimit;
  Definition.RestartDelayMilliseconds := DefaultRestartDelayMilliseconds;
  Definition.Readiness := ReadyWhenStarted;
  Definition.ReadyTimeoutMilliseconds := DefaultReadyTimeoutMilliseconds;
  Definition.OnConsole := False;
end;

function IsServiceName(const Name: string): Boolean;
var
  Index: LongInt;
begin
  Result := (Length(Name) > 0) and (Length(Name) <= MaximumNameLength);
  for Index := 1 to Length(Name) do
    if not (Name[Index] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      Result := False;
end;

{ Splits Text at spaces; double quotes keep spaces in a word. False if a
  quote is not closed. }
function SplitWords(const Text: string; out Words: TStringArray): Boolean;
var
  Index: LongInt;
  Current: string;
  InQuotes: Boolean;
  HasWord: Boolean;
begin
  Words := nil;
  Current := '';
  InQuotes := False;
  HasWord := False;
  for Index := 1 to Length(Text) do
  begin
    if Text[Index] = '"' then
    begin
      InQuotes := not InQuotes;
      HasWord := True;
    end
    else if (Text[Index] in [' ', #9]) and not InQuotes then
    begin
      if HasWord then
      begin
        SetLength(Words, Length(Words) + 1);
        Words[High(Words)] := Current;
      end;
      Current := '';
      HasWord := False;
    end
    else
    begin
      Current := Current + Text[Index];
      HasWord := True;
    end;
  end;
  if HasWord then
  begin
    SetLength(Words, Length(Words) + 1);
    Words[High(Words)] := Current;
  end;
  Result := not InQuotes;
end;

{ "1", "0.5", "2.25" -> milliseconds. }
function ParseSeconds(const Text: string; out Milliseconds: LongInt): Boolean;
var
  Index: LongInt;
  WholeSeconds: LongInt;
  Fraction: LongInt;
  FractionDigits: LongInt;
  SeenPoint: Boolean;
begin
  Result := False;
  Milliseconds := 0;
  WholeSeconds := 0;
  Fraction := 0;
  FractionDigits := 0;
  SeenPoint := False;
  if Text = '' then
    Exit;
  for Index := 1 to Length(Text) do
  begin
    if (Text[Index] = '.') and not SeenPoint then
      SeenPoint := True
    else if Text[Index] in ['0'..'9'] then
    begin
      if not SeenPoint then
      begin
        WholeSeconds := WholeSeconds * 10 + Ord(Text[Index]) - Ord('0');
        if WholeSeconds > MaximumSeconds then
          Exit;
      end
      else if FractionDigits < 3 then
      begin
        Fraction := Fraction * 10 + Ord(Text[Index]) - Ord('0');
        Inc(FractionDigits);
      end;
    end
    else
      Exit;
  end;
  while FractionDigits < 3 do
  begin
    Fraction := Fraction * 10;
    Inc(FractionDigits);
  end;
  Milliseconds := WholeSeconds * 1000 + Fraction;
  Result := True;
end;

function ParseCount(const Text: string; out Count: LongInt): Boolean;
begin
  Result := TryStrToInt(Text, Count) and (Count >= 0) and (Count <= 1000);
end;

function ParseYesNo(const Text: string; out Value: Boolean): Boolean;
begin
  Result := True;
  if Text = 'yes' then
    Value := True
  else if Text = 'no' then
    Value := False
  else
    Result := False;
end;

{ Takes one "key = value" into Definition; '' or what is wrong. }
function ApplySetting(const Key, Value: string; var Definition: TServiceDefinition): string;
var
  Words: TStringArray;
  Index: LongInt;
begin
  Result := '';
  if Key = 'description' then
    Definition.Description := Value
  else if Key = 'program' then
  begin
    if (Value = '') or (Value[1] <> '/') then
      Exit('the program must be an absolute path');
    Definition.ProgramPath := Value;
  end
  else if Key = 'arguments' then
  begin
    if not SplitWords(Value, Definition.Arguments) then
      Exit('a quote is not closed');
  end
  else if Key = 'user' then
  begin
    if Value = '' then
      Exit('no user is named');
    Definition.UserName := Value;
  end
  else if Key = 'needs' then
  begin
    SplitWords(Value, Words);
    for Index := 0 to High(Words) do
      if not IsServiceName(Words[Index]) then
        Exit('"' + Words[Index] + '" cannot name a service');
    Definition.Needs := Words;
  end
  else if Key = 'modes' then
    SplitWords(Value, Definition.Modes)
  else if Key = 'restart' then
  begin
    if Value = 'never' then
      Definition.Restart := RestartNever
    else if Value = 'on-failure' then
      Definition.Restart := RestartOnFailure
    else if Value = 'always' then
      Definition.Restart := RestartAlways
    else
      Exit('restart is never, on-failure or always');
  end
  else if Key = 'restart-limit' then
  begin
    if not ParseCount(Value, Definition.RestartLimit) then
      Exit('restart-limit is a number from 0 to 1000');
  end
  else if Key = 'restart-delay' then
  begin
    if not ParseSeconds(Value, Definition.RestartDelayMilliseconds) then
      Exit('restart-delay is a number of seconds');
  end
  else if Key = 'ready' then
  begin
    if Value = 'started' then
      Definition.Readiness := ReadyWhenStarted
    else if Value = 'notify' then
      Definition.Readiness := ReadyWhenNotified
    else
      Exit('ready is started or notify');
  end
  else if Key = 'ready-timeout' then
  begin
    if not ParseSeconds(Value, Definition.ReadyTimeoutMilliseconds) then
      Exit('ready-timeout is a number of seconds');
  end
  else if Key = 'console' then
  begin
    if not ParseYesNo(Value, Definition.OnConsole) then
      Exit('console is yes or no');
  end
  else
    Result := 'unknown setting "' + Key + '"';
end;

function ParseDefinition(Lines: TStringArray; var Definition: TServiceDefinition; out Problem: string): Boolean;
var
  LineIndex: LongInt;
  Line: string;
  EqualsAt: LongInt;
  Key: string;
  Value: string;
  Wrong: string;
begin
  Problem := '';
  for LineIndex := 0 to High(Lines) do
  begin
    Line := Trim(Lines[LineIndex]);
    if (Line = '') or (Line[1] = '#') then
      Continue;
    EqualsAt := Pos('=', Line);
    if EqualsAt = 0 then
    begin
      Problem := 'line ' + IntToStr(LineIndex + 1) + ': "key = value" expected';
      Exit(False);
    end;
    Key := Trim(Copy(Line, 1, EqualsAt - 1));
    Value := Trim(Copy(Line, EqualsAt + 1, Length(Line)));
    Wrong := ApplySetting(Key, Value, Definition);
    if Wrong <> '' then
    begin
      Problem := 'line ' + IntToStr(LineIndex + 1) + ': ' + Wrong;
      Exit(False);
    end;
  end;
  if Definition.ProgramPath = '' then
  begin
    Problem := 'no program is named';
    Exit(False);
  end;
  Result := True;
end;

function ReadDefinitionFile(const Path, Name: string; out Definition: TServiceDefinition; out Problem: string): Boolean;
var
  Contents: TStringList;
  Lines: TStringArray;
  Index: LongInt;
begin
  DefaultDefinition(Name, Definition);
  Contents := TStringList.Create;
  try
    try
      Contents.LoadFromFile(Path);
    except
      on Error: Exception do
      begin
        Problem := 'cannot be read';
        Exit(False);
      end;
    end;
    SetLength(Lines, Contents.Count);
    for Index := 0 to Contents.Count - 1 do
      Lines[Index] := Contents[Index];
  finally
    Contents.Free;
  end;
  Result := ParseDefinition(Lines, Definition, Problem);
end;

function BelongsToMode(const Definition: TServiceDefinition; const Mode: string): Boolean;
var
  Index: LongInt;
begin
  for Index := 0 to High(Definition.Modes) do
    if Definition.Modes[Index] = Mode then
      Exit(True);
  Result := False;
end;

function RestartPolicyName(Policy: TRestartPolicy): string;
begin
  case Policy of
    RestartNever: Result := 'never';
    RestartOnFailure: Result := 'on-failure';
  else
    Result := 'always';
  end;
end;

function ReadinessName(Readiness: TReadiness): string;
begin
  if Readiness = ReadyWhenNotified then
    Result := 'notify'
  else
    Result := 'started';
end;

end.
