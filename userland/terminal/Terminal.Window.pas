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
  The terminal window: the view (Terminal.View) filling a window, and
  the shell's session (Terminal.Session) behind it.

  The window starts the size of the grid it is given (the size the
  last terminal window had when it closed, Terminal.Settings), and the
  size it has when it closes is kept for the next one. Output goes to
  the view, typing and pasting to the session, and a new size of the
  view's grid to the pseudo-terminal. Programs set the window's title
  (OSC 0 and 2); a bell flashes the view for a moment. Closing the
  window hangs the terminal up, which ends the shell; the shell ending
  closes the window. Each step is written to standard output, for the
  tests.
}
unit Terminal.Window;

{$mode objfpc}
{$H+}

interface

uses
  Windowing.Windows,
  Controls.Window,
  Terminal.View,
  Terminal.Session;

type
  TTerminalWindow = class(TControlWindow)
  private
    FView: TTerminalView;
    FSession: TTerminalSession;
    { Where it was placed (logical units). }
    FLeft: LongInt;
    FTop: LongInt;
    procedure ViewInput(const Bytes: string);
    procedure GridResized(Rows, Columns: LongInt);
    procedure SessionOutput(Data: PByte; Count: LongInt);
    procedure SessionEnded(ExitCode: LongInt);
    procedure TitleChanged(const NewTitle: string);
    procedure Reply(const Text: string);
    procedure Bell;
    procedure RememberSize;
  protected
    procedure CloseRequested; override;
    procedure TimerFired(TimerId: LongWord); override;
  public
    constructor Create(Left, Top, Rows, Columns: LongInt);
    destructor Destroy; override;
    { Starts ShellPath on a new pseudo-terminal; False if it could not. }
    function StartShell(ShellPath: PChar): Boolean;
  end;

implementation

uses
  SysUtils,
  Sys.Streams,
  Sys.Format,
  Windowing.Connection,
  Controls.Base,
  Terminal.Settings;

const
  FlashTimer = 1;
  FlashMilliseconds = 100;
  { How long a hung-up shell is given to end. }
  HangUpWaitMilliseconds = 2000;
  DefaultTitle = 'Terminal';

constructor TTerminalWindow.Create(Left, Top, Rows, Columns: LongInt);
var
  Measure: TTerminalView;
  Width: LongInt;
  Height: LongInt;
begin
  { The window's size comes from the view's cells: measured with a view
    that is not shown, at the scale new windows start at. }
  Measure := TTerminalView.Create(nil);
  Measure.SizeForGrid(Rows, Columns, Width, Height);
  Measure.Free;
  inherited Create(DefaultTitle, Left, Top, Unscaled(Width), Unscaled(Height));
  FLeft := Left;
  FTop := Top;
  { The session first: laying the view out tells it the grid's size. }
  FSession := TTerminalSession.Create;
  FSession.OnOutput := @SessionOutput;
  FSession.OnEnded := @SessionEnded;
  FView := TTerminalView.Create(Root);
  FView.Align := AlignClient;
  FView.OnInput := @ViewInput;
  FView.OnGridResized := @GridResized;
  FView.Emulator.OnTitle := @TitleChanged;
  FView.Emulator.OnReply := @Reply;
  FView.Emulator.OnBell := @Bell;
  FocusControl(FView);
end;

destructor TTerminalWindow.Destroy;
begin
  FSession.Free;
  inherited Destroy;
end;

function TTerminalWindow.StartShell(ShellPath: PChar): Boolean;
var
  Error: LongInt;
  CellWidth: LongInt;
  CellHeight: LongInt;
begin
  Error := FSession.Start(ShellPath, FView.Emulator.Screen.Rows, FView.Emulator.Screen.Columns);
  Result := Error = 0;
  FView.CellSize(CellWidth, CellHeight);
  if Result then
    WriteFormatted(StandardOutput,
      'terminal: /dev/pts%d, %d rows, %d columns, window at %d,%d, %dx%d pixels, cells %dx%d'#10,
      [ArgumentNumber(FSession.Number), ArgumentNumber(FView.Emulator.Screen.Rows),
       ArgumentNumber(FView.Emulator.Screen.Columns), ArgumentNumber(FLeft), ArgumentNumber(FTop),
       ArgumentNumber(PixelWidth), ArgumentNumber(PixelHeight), ArgumentNumber(CellWidth),
       ArgumentNumber(CellHeight)])
  else
    WriteFormatted(StandardError, 'terminal: cannot start %s: error %d'#10,
      [ArgumentText(ShellPath), ArgumentNumber(Error)]);
  FlushStream(StandardOutput);
end;

procedure TTerminalWindow.ViewInput(const Bytes: string);
begin
  FSession.Send(Bytes);
end;

procedure TTerminalWindow.Reply(const Text: string);
begin
  FSession.Send(Text);
end;

procedure TTerminalWindow.GridResized(Rows, Columns: LongInt);
begin
  FSession.Resize(Rows, Columns);
  WriteFormatted(StandardOutput, 'terminal: %d rows, %d columns'#10, [ArgumentNumber(Rows),
    ArgumentNumber(Columns)]);
  FlushStream(StandardOutput);
end;

procedure TTerminalWindow.SessionOutput(Data: PByte; Count: LongInt);
begin
  FView.ShowOutput(Data, Count);
end;

procedure TTerminalWindow.TitleChanged(const NewTitle: string);
begin
  if NewTitle = '' then
    Title := DefaultTitle
  else
    Title := NewTitle;
end;

procedure TTerminalWindow.Bell;
begin
  FView.Flash(True);
  StartTimer(FlashTimer, FlashMilliseconds);
end;

procedure TTerminalWindow.TimerFired(TimerId: LongWord);
begin
  if TimerId <> FlashTimer then
    Exit;
  StopTimer(FlashTimer);
  FView.Flash(False);
end;

procedure TTerminalWindow.RememberSize;
begin
  RememberGridSize(FView.Emulator.Screen.Rows, FView.Emulator.Screen.Columns);
end;

procedure TTerminalWindow.SessionEnded(ExitCode: LongInt);
begin
  RememberSize;
  WriteFormatted(StandardOutput, 'terminal: the shell ended with status %d'#10, [ArgumentNumber(ExitCode)]);
  FlushStream(StandardOutput);
  Free;
end;

procedure TTerminalWindow.CloseRequested;
var
  ExitCode: LongInt;
begin
  RememberSize;
  ExitCode := FSession.Close(HangUpWaitMilliseconds);
  WriteFormatted(StandardOutput, 'terminal: closed; the shell ended with status %d'#10, [ArgumentNumber(ExitCode)]);
  FlushStream(StandardOutput);
  Free;
end;

end.
