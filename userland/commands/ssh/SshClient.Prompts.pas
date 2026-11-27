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
  Questions to the person at the terminal: a password (not echoed), an
  answer to a server's prompt, yes or no for a new host key. They go to
  the terminal itself - standard input when it is one, else /dev/tty -
  so that ssh can be given a command's input on a pipe and still ask.
  With BatchMode, or without a terminal, nothing is asked.
}
unit SshClient.Prompts;

{$mode objfpc}{$H+}

interface

{ False when there is no terminal to ask (or nothing was typed before
  the end). }
function AskLine(const Prompt: string; Echo: Boolean; out Answer: string): Boolean;
function AskYesNo(const Question: string): Boolean;
procedure SetPromptsAllowed(Allowed: Boolean);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Console,
  Sys.Files,
  Sys.Kernel;

var
  PromptsAllowed: Boolean = True;

procedure SetPromptsAllowed(Allowed: Boolean);
begin
  PromptsAllowed := Allowed;
end;

procedure WriteText(Handle: Int64; const Text: string);
begin
  if Text <> '' then
    KernelWrite(Handle, @Text[1], Length(Text));
end;

function AskLine(const Prompt: string; Echo: Boolean; out Answer: string): Boolean;
var
  Handle: Int64;
  OwnHandle: Boolean;
  SavedMode: Int64;
  Character: Char;
  Count: Int64;
begin
  Answer := '';
  Result := False;
  if not PromptsAllowed then
    Exit;
  OwnHandle := False;
  if IsConsole(StandardInputHandle) then
    Handle := StandardInputHandle
  else
  begin
    Handle := OpenFile('/dev/tty', OpenRead or OpenWrite);
    if Handle < 0 then
      Exit;
    OwnHandle := True;
  end;
  if OwnHandle then
    WriteText(Handle, Prompt)
  else
    WriteText(StandardErrorHandle, Prompt);
  SavedMode := GetConsoleMode(Handle);
  if (SavedMode >= 0) and not Echo then
    SetConsoleMode(Handle, LongWord(SavedMode) and not ConsoleModeEcho);
  repeat
    Count := KernelRead(Handle, @Character, 1);
    if Count <= 0 then
      Break;
    if Character = #10 then
    begin
      Result := True;
      Break;
    end;
    if Character <> #13 then
      Answer := Answer + Character;
  until False;
  if SavedMode >= 0 then
    SetConsoleMode(Handle, LongWord(SavedMode));
  if not Echo then
    if OwnHandle then
      WriteText(Handle, #10)
    else
      WriteText(StandardErrorHandle, #10);
  if OwnHandle then
    KernelClose(Handle);
end;

function AskYesNo(const Question: string): Boolean;
var
  Answer: string;
begin
  repeat
    if not AskLine(Question + ' (yes/no)? ', True, Answer) then
      Exit(False);
    Answer := LowerCase(Trim(Answer));
    if Answer = 'yes' then
      Exit(True);
    if Answer = 'no' then
      Exit(False);
  until False;
end;

end.
