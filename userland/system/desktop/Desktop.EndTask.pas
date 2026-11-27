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
  Closing a program that does not respond. The display server marks a
  program that stops answering its pings ("(Not responding)" in its
  titles); when the user then asks to close one of its windows, the
  server tells the shell (EventShellEndTaskOffered) instead of leaving
  the request unheard, and the desktop asks: end the program now (its
  unsaved work is lost) or wait for it. Ending needs no answer from the
  program - the kernel ends it - so a stuck window can always go.
}
unit Desktop.EndTask;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Protocol;

{ The server offered to end the program behind Message (Value: its
  process; Text: the window's title). }
procedure OfferToEndTask(const Message: TWindowMessage);

implementation

uses
  SysUtils,
  Sys.Processes,
  Controls.MessageBoxes,
  Desktop.Report;

const
  { The status a program ended by the user gets (killed). }
  ExitStatusEnded = 137;
  EndTaskChoice = 0;

var
  { The process asked about now (one question at a time per program). }
  AskingAbout: QWord = 0;

procedure OfferToEndTask(const Message: TWindowMessage);
var
  ProcessId: QWord;
  Title: string;
  Options: TChoiceBoxOptions;
  Error: LongInt;
begin
  ProcessId := QWord(LongWord(Message.Value));
  if (ProcessId = 0) or (ProcessId = AskingAbout) then
    Exit;
  Title := MessageText(Message);
  if Title = '' then
    Title := 'This program';
  AskingAbout := ProcessId;
  try
    Options := Default(TChoiceBoxOptions);
    Options.Captions := ['&End task', '&Wait'];
    Options.CancelIndex := 1;
    if ShowChoiceBox('Not responding', Title + ' is not responding.' + LineEnding + LineEnding +
      'If you end it now, any work in it that is not saved will be lost.', Options, SignWarning) <>
      EndTaskChoice then
      Exit;
    Error := TerminateProgram(ProcessId, ExitStatusEnded);
    Say(Format('desktop: ended not responding process %d (%d)', [ProcessId, Error]));
  finally
    AskingAbout := 0;
  end;
end;

end.
