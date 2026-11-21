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
  A process's properties: everything the kernel tells about it, in a
  dialog of captions and values - who it is and runs as, its command
  line and terminal, when it started, its threads, handles and
  priority, its processor time (user mode and kernel) and its memory
  (what it has, of which its own and shared, the most it had, and the
  size of what it may touch). It shows the process as it was when the
  dialog opened.
}
unit TaskManager.PropertiesDialog;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Sys.ProcessList;

procedure ShowProcessProperties(Owner: TWindow; const Details: TProcessDetails);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Time,
  Sys.Threads,
  Controls.Labels,
  Controls.Dialogs,
  TaskManager.Formatting,
  TaskManager.Output;

const
  { Logical units. }
  DialogWidth = 400;
  Margin = 12;
  CaptionWidth = 120;
  RowHeight = 18;
  ButtonWidth = 75;
  ButtonHeight = 23;
  RowCount = 18;

type
  TPropertiesDialog = class(TDialog)
  private
    FNextRow: LongInt;
    procedure AddRow(const Caption, Value: string);
    procedure AddRows(const Details: TProcessDetails);
  public
    constructor CreateFor(OwnerWindow: TWindow; const Details: TProcessDetails);
  end;

function StartedText(const Details: TProcessDetails): string;
var
  Moment: Sys.Time.TDateTime;
begin
  { (The clock keeps universal time; there are no time zones yet.) }
  DecodeTime(Details.StartTime, Moment);
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d, running for %s', [Moment.Year, Moment.Month, Moment.Day,
    Moment.Hour, Moment.Minute, Moment.Second,
    FormatDuration((UptimeMilliseconds - Details.StartUptimeMilliseconds) div 1000)]);
end;

function UserText(const Details: TProcessDetails): string;
begin
  Result := UserName(Details.EffectiveUserId);
  if Details.RealUserId <> Details.EffectiveUserId then
    Result := Result + ' (started by ' + UserName(Details.RealUserId) + ')';
end;

function CommandLineText(const Details: TProcessDetails): string;
begin
  if (Details.Flags and ProcessDetailsCommandLineHidden) <> 0 then
    Result := '(another user''s)'
  else
    Result := StrPas(@Details.CommandLine[0]);
end;

{ The names of the process's threads (CallSetThreadName), as the kernel
  lists them. }
function ThreadNamesText(const Details: TProcessDetails): string;
var
  Threads: TThreadDetailsList;
  Index: Integer;
begin
  Result := '';
  if ListThreads(Details.ProcessId, Threads) < 0 then
    Exit('(ended)');
  for Index := 0 to High(Threads) do
  begin
    if Index > 0 then
      Result := Result + ', ';
    Result := Result + Threads[Index].Name;
  end;
end;

function TerminalText(const Details: TProcessDetails): string;
begin
  if Details.Terminal[0] = #0 then
    Result := '(none)'
  else
    Result := StrPas(@Details.Terminal[0]);
end;

constructor TPropertiesDialog.CreateFor(OwnerWindow: TWindow; const Details: TProcessDetails);
var
  Height: LongInt;
begin
  Height := Margin + RowCount * RowHeight + Margin + ButtonHeight + Margin;
  inherited CreateDialog(StrPas(@Details.Name[0]) + ' Properties', DialogWidth, Height, OwnerWindow);
  AddRows(Details);
  AddButton('OK', ResultOk, DialogWidth - Margin - ButtonWidth, Height - Margin - ButtonHeight, ButtonWidth,
    ButtonHeight, True, True);
  FocusControl(DefaultControl);
end;

procedure TPropertiesDialog.AddRow(const Caption, Value: string);
var
  Text: TLabel;
  Top: LongInt;
begin
  Top := Margin + FNextRow * RowHeight;
  Text := TLabel.Create(Root);
  Text.ShowsMnemonic := False;
  Text.Text := Caption;
  Text.SetBounds(Margin, Top, CaptionWidth, RowHeight);
  Text := TLabel.Create(Root);
  Text.ShowsMnemonic := False;
  Text.Text := Value;
  Text.SetBounds(Margin + CaptionWidth, Top, DialogWidth - 2 * Margin - CaptionWidth, RowHeight);
  Inc(FNextRow);
end;

procedure TPropertiesDialog.AddRows(const Details: TProcessDetails);
begin
  AddRow('Name:', StrPas(@Details.Name[0]));
  AddRow('Process ID:', IntToStr(Details.ProcessId) + ', started by ' + IntToStr(Details.ParentProcessId));
  AddRow('User:', UserText(Details));
  AddRow('Command line:', CommandLineText(Details));
  AddRow('Terminal:', TerminalText(Details));
  AddRow('Session, group:', IntToStr(Details.SessionId) + ', ' + IntToStr(Details.GroupId));
  AddRow('State:', ProcessStateName(Details.State));
  AddRow('Started:', StartedText(Details));
  AddRow('Threads, handles:', IntToStr(Details.ThreadCount) + ', ' + IntToStr(Details.HandleCount));
  AddRow('Thread names:', ThreadNamesText(Details));
  AddRow('Priority:', IntToStr(Details.Priority) + ' (nice ' + IntToStr(Details.Nice) + ')');
  AddRow('Processor time:', FormatProcessorTime(Details.ProcessorNanoseconds));
  AddRow('  in the program:', FormatProcessorTime(Details.UserNanoseconds));
  AddRow('  in the kernel:', FormatProcessorTime(Details.KernelNanoseconds));
  AddRow('Memory:', FormatBytes(Details.ResidentBytes) + ' (most so far ' + FormatBytes(Details.PeakResidentBytes) +
    ')');
  AddRow('  its own:', FormatBytes(Details.PrivateBytes));
  AddRow('  shared:', FormatBytes(Details.SharedBytes));
  AddRow('Address space:', FormatBytes(Details.VirtualBytes));
end;

procedure ShowProcessProperties(Owner: TWindow; const Details: TProcessDetails);
var
  Dialog: TPropertiesDialog;
begin
  Dialog := TPropertiesDialog.CreateFor(Owner, Details);
  try
    Say('properties ' + IntToStr(Details.ProcessId) + ' ' + StrPas(@Details.Name[0]) + ' ' +
      IntToStr(Details.ThreadCount) + ' ' + IntToStr(Details.ResidentBytes div 1024));
    Dialog.ShowModal;
  finally
    Dialog.Free;
  end;
end;

end.
